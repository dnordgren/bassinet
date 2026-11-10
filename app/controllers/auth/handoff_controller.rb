module Auth
  # The iOS standalone handoff, docs/auth.md §2.
  #
  #   POST /auth/handoff           -> { code, poll_id, safari_url }  (app, no session)
  #   GET  /auth/handoff/:code     -> park code in Safari's session, then Google OAuth
  #   GET  /auth/handoff/poll/:id  -> 204 while waiting, 200 when claimed
  #   POST /auth/handoff/session   -> redeem the claimed poll id for a real cookie
  #
  # The poll id lives only in an HttpOnly encrypted cookie in the app's own
  # browser. It is single-use, expires in 10 minutes, and yields nothing until
  # someone actually completes Google OAuth in Safari.
  class HandoffController < ApplicationController
    skip_before_action :verify_authenticity_token, only: %i[create poll]

    HANDOFF_COOKIE = "bassinet_handoff".freeze

    # App side, step 1.
    def create
      handoff = Bassinet::HandoffRepo.new.create

      cookies.encrypted[HANDOFF_COOKIE] = {
        value: handoff[:poll_id],
        expires: 15.minutes,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      render json: {
        code: handoff[:code],
        poll_id: handoff[:poll_id],
        expires_at: handoff[:expires_at],
        safari_url: auth_handoff_entry_url(code: handoff[:code])
      }
    end

    # Safari side: remember the code in this browser, then go through Google.
    # If this browser is already signed in, claim immediately.
    def entry
      code = params[:code].to_s.upcase
      @code = code
      handoff = Bassinet::HandoffRepo.new.find_by_code(code)

      unless Bassinet::HandoffRepo.new.usable?(handoff)
        return redirect_to sign_in_path,
                           alert: "That sign-in code has expired. Start again from the app."
      end

      session[:handoff_code] = code

      return redirect_to auth_start_path unless signed_in?

      Bassinet::HandoffRepo.new.claim!(code, user_id: current_user.user_id)
      @finished = true
      render :finished
    rescue Bassinet::Dynamo::Client::Conflict
      # Someone else already claimed it; the app will find out when it polls.
      @finished = true
      render :finished
    end

    # App side, step 2. Keep this cheap — it is polled every ~2s.
    def poll
      poll_id = params[:id].presence || cookies.encrypted[HANDOFF_COOKIE]
      case Bassinet::HandoffRepo.new.status_for_poll(poll_id.to_s)
      when :claimed
        render json: { status: "claimed" }
      when :waiting
        head :no_content
      else
        head :gone
      end
    end

    # App side, step 3.
    def session_create
      poll_id = cookies.encrypted[HANDOFF_COOKIE]
      return render json: { error: "no_pending_handoff" }, status: :unauthorized if poll_id.blank?

      user_id = Bassinet::HandoffRepo.new.redeem!(poll_id)
      user = Bassinet::UserRepo.new.find(user_id)
      return render json: { error: "unknown_user" }, status: :unauthorized if user.nil?

      household = Bassinet::UserRepo.new.households_for(user_id).first
      sign_in!(user_id: user_id, household_id: household&.fetch("household_id", nil))
      cookies.delete(HANDOFF_COOKIE)

      render json: { ok: true, user: user.as_json }
    rescue Bassinet::Dynamo::Client::Conflict, Bassinet::Dynamo::Client::NotFound
      render json: { error: "handoff_invalid" }, status: :conflict
    end

    # Safari side, after OAuth has already claimed: tell them to go back.
    def finished
      @finished = true
      render :finished
    end
  end
end
