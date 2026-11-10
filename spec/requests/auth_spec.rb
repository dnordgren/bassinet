require "rails_helper"

RSpec.describe "Authentication", type: :request do
  # The app reads credentials from class methods, so stubbing them here makes
  # the whole flow exercisable without real Google secrets.
  before do
    allow(Bassinet::GoogleOAuth).to receive(:client_id).and_return("client-abc")
    allow(Bassinet::GoogleOAuth).to receive(:client_secret).and_return("secret-xyz")
    allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(true)
  end

  def stub_google(exchange: nil, error: nil)
    if error
      allow_any_instance_of(Bassinet::GoogleOAuth)
        .to receive(:exchange).and_raise(Bassinet::GoogleOAuth::Error, error)
    else
      allow_any_instance_of(Bassinet::GoogleOAuth)
        .to receive(:exchange).and_return(exchange)
    end
  end

  def identity(sub: "google-sub-1", email: "derek@example.com", name: "Derek")
    Bassinet::GoogleOAuth::Identity.new(
      sub: sub, email: email, email_verified: true, name: name, picture: nil
    )
  end

  # Walks the real OAuth flow so the session cookie is written by the app
  # itself. Hand-building an encrypted cookie would prove nothing about
  # whether sign-in actually works.
  def sign_in_via_google!(sub: "google-sub-1", email: "derek@example.com", name: "Derek")
    stub_google(exchange: identity(sub: sub, email: email, name: name))

    get auth_start_path
    state = oauth_state_from_redirect

    get auth_callback_path, params: { code: "auth-code", state: state }
    expect(response).to redirect_to(root_path), "sign-in failed: #{response.body[0, 200]}"

    Bassinet::UserRepo.new.find(sub)
  end

  def oauth_state_from_redirect
    location = response.headers["Location"].to_s
    URI.decode_www_form(URI(location).query.to_s).to_h["state"]
  end

  describe "GET /sign-in" do
    it "renders the sign-in screen" do
      get sign_in_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Bassinet")
    end

    it "offers the Google button when configured" do
      get sign_in_path
      expect(response.body).to include("Continue with Google")
    end

    it "explains that Google is unconfigured rather than showing a dead button" do
      allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(false)

      get sign_in_path
      expect(response.body).to include("not configured")
      expect(response.body).not_to include("Continue with Google")
    end

    it "redirects home when already signed in" do
      sign_in_via_google!

      get sign_in_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /" do
    it "bounces anonymous visitors to sign-in" do
      get root_path
      expect(response).to redirect_to(sign_in_path)
    end

    it "renders the app shell when signed in" do
      sign_in_via_google!

      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add your first child")
    end

    it "shows the child once one exists" do
      user = sign_in_via_google!
      household_id = Bassinet::UserRepo.new.households_for(user.user_id).first["household_id"]
      Bassinet::ChildRepo.new(household_id: household_id)
                         .create(child_id: "ch_1", name: "Mabel", birth_date: Date.today.to_s)

      get root_path
      expect(response.body).to include("Mabel")
      expect(response.body).not_to include("Add your first child")
    end

    it "does not leak another household's children" do
      sign_in_via_google!(sub: "sub-a", email: "a@example.com", name: "A")
      other = Bassinet::UserRepo.new.provision!(user_id: "sub-b", email: "b@example.com", name: "B")
      Bassinet::ChildRepo.new(household_id: other[:household_id])
                         .create(child_id: "ch_b", name: "NotYours")

      get root_path
      expect(response.body).not_to include("NotYours")
    end
  end

  describe "GET /auth/start" do
    it "redirects to Google with state and an S256 PKCE challenge" do
      get auth_start_path

      expect(response).to have_http_status(:redirect)
      location = response.headers["Location"]
      expect(location).to start_with("https://accounts.google.com/o/oauth2/v2/auth")
      expect(location).to include("code_challenge_method=S256")
      expect(location).to include("code_challenge=")
      expect(location).to include("state=")

      # The client secret must never appear in a URL the browser sees.
      expect(location).not_to include("secret-xyz")
    end

    it "requests only the three non-sensitive scopes" do
      get auth_start_path
      location = response.headers["Location"]

      expect(location).to include("scope=openid")
      expect(location).to include("email")
      expect(location).to include("profile")
      expect(location).not_to include("drive")
      expect(location).not_to include("calendar")
    end

    it "explains instead of redirecting when unconfigured" do
      allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(false)

      get auth_start_path
      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /auth/google/callback" do
    it "creates a user, household and session on first sign-in" do
      stub_google(exchange: identity)

      get auth_start_path
      state = oauth_state_from_redirect

      expect do
        get auth_callback_path, params: { code: "abc", state: state }
      end.to change { Bassinet::UserRepo.new.find("google-sub-1") }.from(nil).to(instance_of(Bassinet::User))

      expect(response).to redirect_to(root_path)

      households = Bassinet::UserRepo.new.households_for("google-sub-1")
      expect(households.size).to eq(1)
      expect(Bassinet::HouseholdRepo.new(household_id: households.first["household_id"]).members.size).to eq(1)
    end

    it "establishes a session that survives to the next request" do
      sign_in_via_google!

      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "reuses the existing account on a second sign-in" do
      sign_in_via_google!

      expect do
        # A fresh browser: clear cookies so this is a genuine second login.
        reset!
        sign_in_via_google!
      end.not_to change { Bassinet::UserRepo.new.households_for("google-sub-1").size }
    end

    it "keeps the same user id and household across logins" do
      first = sign_in_via_google!
      first_household = Bassinet::UserRepo.new.households_for(first.user_id).first["household_id"]

      reset!
      second = sign_in_via_google!
      second_household = Bassinet::UserRepo.new.households_for(second.user_id).first["household_id"]

      expect(second.user_id).to eq(first.user_id)
      expect(second_household).to eq(first_household)
    end

    it "rejects a callback with no matching state" do
      stub_google(exchange: identity)

      get auth_callback_path, params: { code: "abc", state: "forged" }

      expect(response).to redirect_to(sign_in_path)
      expect(Bassinet::UserRepo.new.find("google-sub-1")).to be_nil
    end

    it "rejects a callback that replays an already-used state" do
      stub_google(exchange: identity)
      get auth_start_path
      state = oauth_state_from_redirect
      get auth_callback_path, params: { code: "abc", state: state }

      # State is single-use; a replay must not mint another session.
      get auth_callback_path, params: { code: "abc", state: state }
      expect(response).to redirect_to(sign_in_path)
    end

    it "handles a cancelled consent screen" do
      get auth_callback_path, params: { error: "access_denied" }
      expect(response).to redirect_to(sign_in_path)
    end

    it "handles a token exchange failure without creating anyone" do
      stub_google(error: "token endpoint returned 400: invalid_grant")
      get auth_start_path
      state = oauth_state_from_redirect

      get auth_callback_path, params: { code: "bad", state: state }

      expect(response).to redirect_to(sign_in_path)
      expect(Bassinet::UserRepo.new.find("google-sub-1")).to be_nil
    end
  end

  describe "sign out" do
    it "revokes the session server-side so the cookie stops working" do
      sign_in_via_google!

      get root_path
      expect(response).to have_http_status(:ok)

      delete sign_out_path
      expect(response).to redirect_to(sign_in_path)

      get root_path
      expect(response).to redirect_to(sign_in_path)
    end

    it "revokes the session record, not just the cookie" do
      user = sign_in_via_google!
      delete sign_out_path

      # Even a captured cookie would be useless: the server-side record is gone.
      expect(Bassinet::SessionRepo.new.active_for(user.user_id)).to be_empty
    end
  end
end
