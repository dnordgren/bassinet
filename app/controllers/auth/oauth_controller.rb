module Auth
  # Google sign-in, start and callback.
  #
  # State and PKCE verifier live in the Rails session cookie — short-lived,
  # single-use, and never persisted server-side. That's enough: the code
  # exchange is bound to the verifier, so an intercepted `code` alone is inert.
  class OAuthController < ApplicationController
    skip_before_action :verify_authenticity_token, only: :callback

    def start
      unless Bassinet::GoogleOAuth.configured?
        return redirect_to sign_in_path,
                           alert: "Google sign-in is not configured yet. Add the client ID and secret."
      end

      verifier = Bassinet::GoogleOAuth.generate_verifier
      state = SecureRandom.urlsafe_base64(24)

      session[:oauth_state] = state
      session[:oauth_verifier] = verifier
      session[:oauth_at] = Time.current.to_i

      redirect_to Bassinet::GoogleOAuth.new.authorize_url(
        state: state,
        code_verifier: verifier,
        prompt: params[:prompt].presence
      ), allow_other_host: true
    end

    def callback
      if params[:error].present?
        return redirect_to sign_in_path, alert: "Sign-in was cancelled."
      end

      unless valid_state?
        return redirect_to sign_in_path, alert: "That sign-in link expired. Try again."
      end

      identity = exchange_code!
      return redirect_to sign_in_path, alert: "Could not verify that Google account." if identity.nil?

      user, household_id = find_or_provision(identity)

      # Safari-side handoff: if this browser arrived via /handoff/:code, tie the
      # just-signed-in account to that code so the waiting PWA can redeem it.
      finish_handoff_if_pending(user.user_id)

      sign_in!(user_id: user.user_id, household_id: household_id)

      redirect_to(root_path, notice: "Signed in as #{user.display_name}.")
    end

    private

    def valid_state?
      stored = session.delete(:oauth_state)
      verifier = session.delete(:oauth_verifier)
      started_at = session.delete(:oauth_at)

      return false if stored.blank? || verifier.blank?
      return false if params[:state].blank? || !ActiveSupport::SecurityUtils.secure_compare(stored, params[:state].to_s)
      return false if started_at.present? && Time.current.to_i - started_at.to_i > 600

      @verifier = verifier
      true
    end

    def exchange_code!
      Bassinet::GoogleOAuth.new.exchange(
        code: params[:code].to_s,
        code_verifier: @verifier
      )
    rescue Bassinet::GoogleOAuth::Error => e
      Rails.logger.warn("google oauth failed: #{e.message}")
      nil
    end

    # Google gives us a stable `sub`; email is display data and a lookup index.
    # First login provisions a user, their household, and the owner membership
    # in one transaction.
    def find_or_provision(identity)
      repo = Bassinet::UserRepo.new

      if (existing = repo.find(identity.sub))
        repo.refresh_profile(identity.sub,
                             email: identity.email,
                             name: identity.name,
                             avatar_url: identity.picture)
        household = repo.households_for(identity.sub).first
        return [existing, household&.fetch("household_id", nil)]
      end

      result = repo.provision!(
        user_id: identity.sub,
        email: identity.email,
        name: identity.name,
        avatar_url: identity.picture
      )
      [result[:user], result[:household_id]]
    end

    def finish_handoff_if_pending(user_id)
      code = session.delete(:handoff_code)
      return if code.blank?

      Bassinet::HandoffRepo.new.claim!(code, user_id: user_id)
    rescue Bassinet::Dynamo::Client::Error, Bassinet::Dynamo::Client::Conflict => e
      Rails.logger.warn("handoff claim failed: #{e.class}")
    end
  end
end
