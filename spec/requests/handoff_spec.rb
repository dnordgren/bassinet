require "rails_helper"

RSpec.describe "iOS handoff", type: :request do
  before do
    allow(Bassinet::GoogleOAuth).to receive(:client_id).and_return("client-abc")
    allow(Bassinet::GoogleOAuth).to receive(:client_secret).and_return("secret-xyz")
    allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(true)
  end

  let(:repo) { Bassinet::HandoffRepo.new }

  def identity(sub: "google-sub-handoff", email: "derek@example.com", name: "Derek")
    Bassinet::GoogleOAuth::Identity.new(
      sub: sub, email: email, email_verified: true, name: name, picture: nil
    )
  end

  describe "POST /auth/handoff" do
    it "mints a code and a poll id without requiring a session" do
      post auth_handoff_create_path

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body["code"].length).to eq(Bassinet::HandoffRepo::CODE_LENGTH)
      expect(body["poll_id"]).to be_present
      expect(body["safari_url"]).to include(body["code"])
    end

    it "returns a Safari URL that is absolute, not a relative path" do
      post auth_handoff_create_path
      body = JSON.parse(response.body)

      # The app is a standalone PWA and cannot follow a relative URL.
      expect(body["safari_url"]).to match(/\Ahttps?:\/\//)
    end

    it "stores the poll id in an encrypted cookie rather than returning it as the only copy" do
      post auth_handoff_create_path
      # The response body carries it too (the app needs to know), but the cookie
      # is what the server will trust on the redeem request.
      expect(response.cookies["bassinet_handoff"]).to be_present
    end
  end

  describe "GET /auth/handoff/poll/:id" do
    it "returns 204 while Safari has not finished" do
      post auth_handoff_create_path
      poll_id = JSON.parse(response.body)["poll_id"]

      get auth_handoff_poll_path(id: poll_id)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 200 once the handoff is claimed" do
      post auth_handoff_create_path
      body = JSON.parse(response.body)
      repo.claim!(body["code"], user_id: "someone")

      get auth_handoff_poll_path(id: body["poll_id"])
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("claimed")
    end

    it "returns 410 for an unknown poll id" do
      get auth_handoff_poll_path(id: "not-a-real-poll")
      expect(response).to have_http_status(:gone)
    end
  end

  describe "GET /auth/handoff/:code (Safari side)" do
    it "sends an unauthenticated Safari through Google" do
      post auth_handoff_create_path
      code = JSON.parse(response.body)["code"]

      get auth_handoff_entry_path(code: code)

      expect(response).to have_http_status(:redirect)
      expect(response.headers["Location"]).to include("/auth/start")
    end

    it "claims immediately when that Safari is already signed in" do
      # Sign in first in this browser.
      allow_any_instance_of(Bassinet::GoogleOAuth).to receive(:exchange).and_return(identity)
      get auth_start_path
      state = URI.decode_www_form(URI(response.headers["Location"]).query.to_s).to_h["state"]
      get auth_callback_path, params: { code: "c", state: state }
      expect(response).to redirect_to(root_path)

      # Now mint a handoff and arrive with the code.
      post auth_handoff_create_path
      code = JSON.parse(response.body)["code"]

      get auth_handoff_entry_path(code: code)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("signed in")

      expect(repo.find_by_code(code)["status"]).to eq("claimed")
    end

    it "refuses an expired or unknown code" do
      get auth_handoff_entry_path(code: "ZZZZZZ")
      expect(response).to redirect_to(sign_in_path)
    end

    it "accepts a lowercase code typed by hand" do
      post auth_handoff_create_path
      code = JSON.parse(response.body)["code"]

      get auth_handoff_entry_path(code: code.downcase)
      expect(response).to have_http_status(:redirect)
      expect(response.headers["Location"]).to include("/auth/start")
    end
  end

  describe "POST /auth/handoff/session" do
    it "refuses when there is no pending handoff cookie" do
      post auth_handoff_session_path, params: { session_token: "x" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses to redeem a handoff nobody claimed" do
      post auth_handoff_create_path

      post auth_handoff_session_path
      expect(response).to have_http_status(:conflict)
    end

    it "mints a working session once claimed, and only once" do
      post auth_handoff_create_path
      code = JSON.parse(response.body)["code"]
      user_id = Bassinet::UserRepo.new.provision!(user_id: "u_ho", email: "ho@example.com")[:user].user_id
      repo.claim!(code, user_id: user_id)

      post auth_handoff_session_path
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["ok"]).to be(true)

      # The session really works.
      get root_path
      expect(response).to have_http_status(:ok)

      # A replay cannot mint a second session.
      post auth_handoff_session_path
      expect(response).to have_http_status(:unauthorized).or have_http_status(:conflict)
    end
  end

  describe "the full flow, end to end" do
    it "gets an installed-PWA user from no session to a working app" do
      user = Bassinet::UserRepo.new.provision!(user_id: "google-sub-handoff",
                                               email: "derek@example.com",
                                               name: "Derek")[:user]

      # 1. App asks for a handoff.
      post auth_handoff_create_path
      body = JSON.parse(response.body)

      # 2. Safari completes OAuth against that code.
      allow_any_instance_of(Bassinet::GoogleOAuth).to receive(:exchange).and_return(identity)
      get auth_handoff_entry_path(code: body["code"])
      get auth_start_path
      state = URI.decode_www_form(URI(response.headers["Location"]).query.to_s).to_h["state"]
      get auth_callback_path, params: { code: "c", state: state }

      expect(repo.find_by_code(body["code"])["status"]).to eq("claimed")

      # 3. App polls, sees claimed, redeems.
      get auth_handoff_poll_path(id: body["poll_id"])
      expect(JSON.parse(response.body)["status"]).to eq("claimed")

      post auth_handoff_session_path
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["user"]["user_id"]).to eq(user.user_id)

      # 4. The app is usable.
      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add your first child")
    end
  end
end
