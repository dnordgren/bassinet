require "rails_helper"

# Request-level cover for phase 2: child creation and the logging loop.
RSpec.describe "Logging", type: :request do
  before do
    allow(Bassinet::GoogleOAuth).to receive(:client_id).and_return("client-abc")
    allow(Bassinet::GoogleOAuth).to receive(:client_secret).and_return("secret-xyz")
    allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(true)
  end

  def identity(sub:, email:, name:)
    Bassinet::GoogleOAuth::Identity.new(
      sub: sub, email: email, email_verified: true, name: name, picture: nil
    )
  end

  def sign_in!(sub: "google-sub-1", email: "derek@example.com", name: "Derek")
    allow_any_instance_of(Bassinet::GoogleOAuth)
      .to receive(:exchange).and_return(identity(sub: sub, email: email, name: name))

    get auth_start_path
    state = URI.decode_www_form(
      URI(response.headers["Location"]).query.to_s
    ).to_h["state"]

    get auth_callback_path, params: { code: "auth-code", state: state }
    expect(response).to redirect_to(root_path)
    Bassinet::UserRepo.new.find(sub)
  end

  def current_household
    Bassinet::UserRepo.new.households_for(Bassinet::UserRepo.new.find("google-sub-1").user_id).first
  end

  def child_repo
    Bassinet::ChildRepo.new(household_id: current_household["household_id"])
  end

  def event_repo
    Bassinet::EventRepo.new(household_id: current_household["household_id"])
  end

  let(:user) { sign_in! }
  let!(:child) do
    user
    child_repo.create(child_id: "ch_test", name: "Mabel", timezone: "America/Chicago")
  end

  describe "GET /children/new" do
    it "renders the child form" do
      user
      get new_child_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add a child")
    end
  end

  describe "POST /children" do
    it "creates a child and returns home" do
      user
      expect do
        post children_path, params: { child: { name: "Juniper", birth_date: "2026-06-01" } }
      end.to change { child_repo.all.size }.by(1)

      expect(response).to redirect_to(root_path)
      expect(child_repo.all.map(&:name)).to include("Juniper")
    end

    it "surfaces a validation failure instead of a 500" do
      user
      # `let!(:child)` already created one; fill the household to the cap.
      (Bassinet::ChildRepo::MAX_CHILDREN - 1).times do |i|
        child_repo.create(child_id: "ch_fill_#{i}", name: "Fill #{i}")
      end

      post children_path, params: { child: { name: "Eleventh" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("too many children")
    end
  end

  describe "POST /c/:child_id/events (quick tiles)" do
    it "logs a wet diaper in one tap" do
      user
      expect do
        post child_events_path(child.child_id),
             params: { type: "diaper", quick: 1, payload: { kind: "wet" } }
      end.to change { event_repo.for_day(child.child_id, Time.current.to_date).size }.by(1)

      expect(response).to have_http_status(:redirect)
      expect(response.headers["Location"]).to include("/c/ch_test/day/")
    end

    it "starts a timer for sleep" do
      user
      post child_events_path(child.child_id), params: { type: "sleep", quick: 1 }

      running = event_repo.running(child.child_id)
      expect(running).not_to be_nil
      expect(running.type).to eq("sleep")
      expect(running.started_at).not_to be_nil
    end

    it "starts a timer for nursing but not for a bottle" do
      user

      post child_events_path(child.child_id),
           params: { type: "feed", quick: 1, payload: { method: "bottle" } }
      expect(event_repo.running(child.child_id)).to be_nil

      post child_events_path(child.child_id),
           params: { type: "feed", quick: 1, payload: { method: "nursing" } }
      expect(event_repo.running(child.child_id)).not_to be_nil
    end

    it "rejects an invalid payload with a flash and no row" do
      user
      expect do
        post child_events_path(child.child_id),
             params: { type: "diaper", quick: 1, payload: { kind: "sparkling" } }
      end.not_to change { event_repo.for_day(child.child_id, Time.current.to_date).size }

      expect(flash[:alert]).to include("must be one of")
    end
  end

  describe "GET /c/:child_id/events/new" do
    it "renders the detail form for a type" do
      user
      get new_child_event_path(child.child_id, type: "feed")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Log Feed")
    end

    it "rejects an unknown event type" do
      user
      get new_child_event_path(child.child_id, type: "teleport")

      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH /c/:child_id/events/:occurred_at/:event_id" do
    let(:event) do
      user
      event_repo.create(
        child_id: child.child_id, event_id: "evt_1",
        type: "feed", occurred_at: 1_762_699_000_000,
        author_id: "u_1", payload: { "method" => "bottle", "amount_ml" => 90 }
      )
    end

    it "stops a running timer and stamps the duration" do
      user
      started = Bassinet::Dynamo::Marshal.now_ms - 600_000
      sleep_event = event_repo.create(
        child_id: child.child_id, event_id: "evt_sleep",
        type: "sleep", occurred_at: started, author_id: "u_1", started_at: started
      )

      patch child_event_path(child.child_id, sleep_event.occurred_at, sleep_event.event_id),
            params: { type: "sleep", stop: 1 }

      stopped = event_repo.find(child.child_id, "evt_sleep", occurred_at: started)
      expect(stopped.running?).to be(false)
      expect(stopped.duration_s.to_i).to be > 500
    end

    it "applies a payload edit" do
      patch child_event_path(child.child_id, event.occurred_at, event.event_id),
            params: { type: "feed", payload: { method: "bottle", amount_ml: 150 } }

      updated = event_repo.find(child.child_id, "evt_1", occurred_at: 1_762_699_000_000)
      expect(updated.payload["amount_ml"]).to eq(150)
      expect(updated.version).to eq(2)
    end

    it "keeps a required field that a stop request does not resend" do
      user
      started = Bassinet::Dynamo::Marshal.now_ms - 300_000
      nursing = event_repo.create(
        child_id: child.child_id, event_id: "evt_nurse", type: "feed",
        occurred_at: started, author_id: "u_1", started_at: started,
        payload: { "method" => "nursing", "side" => "left" }
      )

      # The Stop button posts only `stop=1` — no payload at all. Before the
      # merge fix this 422'd on the missing `method` and the timer never stopped.
      patch child_event_path(child.child_id, nursing.occurred_at, nursing.event_id),
            params: { type: "feed", stop: 1 }

      expect(response).to have_http_status(:redirect)
      stopped = event_repo.find(child.child_id, "evt_nurse", occurred_at: started)
      expect(stopped.running?).to be(false)
      expect(stopped.payload["method"]).to eq("nursing")
      expect(stopped.payload["side"]).to eq("left")
    end

    it "splits a comma-joined foods field into an array" do
      user
      patch child_event_path(child.child_id, event.occurred_at, event.event_id),
            params: { type: "feed", payload: { method: "solids", foods: ["pear, banana ,,"] } }

      updated = event_repo.find(child.child_id, "evt_1", occurred_at: 1_762_699_000_000)
      expect(updated.payload["foods"]).to eq(%w[pear banana])
    end
  end

  describe "DELETE then restore" do
    it "tombstones, then clears the tombstone on undo" do
      user
      at = 1_762_699_000_000
      event = event_repo.create(
        child_id: child.child_id, event_id: "evt_del", type: "note",
        occurred_at: at, author_id: "u_1", payload: { "body" => "oops" }
      )

      delete delete_child_event_path(child.child_id, event.occurred_at, event.event_id)
      expect(event_repo.find(child.child_id, "evt_del", occurred_at: at).deleted?).to be(true)

      post restore_child_event_path(child.child_id, event.occurred_at, event.event_id)
      restored = event_repo.find(child.child_id, "evt_del", occurred_at: at)
      expect(restored.deleted?).to be(false)
      expect(restored.payload["body"]).to eq("oops")
    end
  end

  describe "GET /c/:child_id/day/:date" do
    it "shows only that day's events" do      user
      zone = ActiveSupport::TimeZone["America/Chicago"]
      today_ms = Bassinet::Dynamo::Marshal.to_ms(zone.now)
      yesterday_ms = today_ms - (24 * 60 * 60 * 1000)

      event_repo.create(child_id: child.child_id, event_id: "today_evt", type: "diaper",
                        occurred_at: today_ms, author_id: "u_1", payload: { "kind" => "wet" })
      event_repo.create(child_id: child.child_id, event_id: "yday_evt", type: "diaper",
                        occurred_at: yesterday_ms, author_id: "u_1", payload: { "kind" => "dirty" })

      get child_day_path(child.child_id, zone.today.to_s)
      expect(response.body).to include("Wet diaper")
      expect(response.body).not_to include("Dirty diaper")
    end

    it "filters by type" do
      user
      zone = ActiveSupport::TimeZone["America/Chicago"]
      now_ms = Bassinet::Dynamo::Marshal.to_ms(zone.now)

      event_repo.create(child_id: child.child_id, event_id: "d1", type: "diaper",
                        occurred_at: now_ms, author_id: "u_1", payload: { "kind" => "wet" })
      event_repo.create(child_id: child.child_id, event_id: "n1", type: "note",
                        occurred_at: now_ms + 1000, author_id: "u_1", payload: { "body" => "sunny day" })

      get child_day_path(child.child_id, zone.today.to_s, type: "note")
      expect(response.body).to include("sunny day")
      expect(response.body).not_to include("Wet diaper")
    end
  end

  describe "household isolation" do
    it "404s (well, redirects home) on another household's child" do
      user
      other = Bassinet::ChildRepo.new(household_id: "hh_someone_else")
                               .create(child_id: "ch_theirs", name: "Not mine")

      get child_day_path(other.child_id, Time.current.to_date.to_s)

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(flash[:alert]).to eq("No such child.")
    end
  end
end
