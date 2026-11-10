class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Request specs send no User-Agent, which this would reject with 406, so it is
  # a production-facing guard only.
  allow_browser versions: :modern unless Rails.env.test?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  SESSION_COOKIE = "bassinet_session".freeze

  helper_method :current_user, :signed_in?, :current_household_id

  # --- session plumbing ---------------------------------------------------

  # The cookie is encrypted *and* signed. It carries only an identifier; the
  # session record in DynamoDB is the real authority, so revoking a session
  # takes effect on the next request rather than whenever a cookie expires.
  def current_session
    return @current_session if defined?(@current_session) && @current_session

    @current_session = load_session
  end

  def load_session
    payload = cookies.encrypted[SESSION_COOKIE]
    return nil if payload.blank?

    user_id = payload["user_id"]
    session_id = payload["session_id"]
    return nil if user_id.blank? || session_id.blank?

    repo = Bassinet::SessionRepo.new
    record = repo.find(user_id, session_id)
    return nil if record.nil?

    repo.touch(user_id, session_id)
    record
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = current_session && Bassinet::UserRepo.new.find(current_session["user_id"])
  end

  def current_household_id
    current_session&.fetch("household_id", nil)
  end

  def signed_in? = current_user.present?

  def sign_in!(user_id:, household_id:)
    session_id = Bassinet::SessionRepo.new.create(
      user_id: user_id,
      household_id: household_id,
      user_agent: request.user_agent,
      ip: request.remote_ip
    )

    cookies.encrypted[SESSION_COOKIE] = {
      value: { "user_id" => user_id, "session_id" => session_id, "household_id" => household_id },
      expires: 90.days,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }

    @current_session = nil
    @current_user = nil
  end

  def sign_out!
    if (record = current_session)
      Bassinet::SessionRepo.new.revoke(record["user_id"], record["session_id"])
    end

    cookies.delete(SESSION_COOKIE, secure: Rails.env.production?, same_site: :lax)
    @current_session = nil
    @current_user = nil
  end

  def require_sign_in!
    return true if signed_in?

    redirect_to sign_in_path, alert: "Please sign in."
    false
  end

  # Any authenticated child operation must go through this. It resolves the
  # child *within the current household*, so a guessed child id from another
  # household is indistinguishable from a missing one.
  def scoped_child!(child_id)
    household_id = current_household_id
    raise Bassinet::Dynamo::Client::NotFound, "no household" if household_id.blank?

    repo = Bassinet::ChildRepo.new(household_id: household_id)
    repo.find!(child_id)
  rescue Bassinet::Dynamo::Client::NotFound
    nil
  end
end
