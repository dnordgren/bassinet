require "rails_helper"

# The logging views are ERB with a lot of helper plumbing; a period in a helper
# breaks the page but not the controller. These render them for real.
RSpec.describe "Logging views", type: :request do
  before do
    allow(Bassinet::GoogleOAuth).to receive(:client_id).and_return("client-abc")
    allow(Bassinet::GoogleOAuth).to receive(:client_secret).and_return("secret-xyz")
    allow(Bassinet::GoogleOAuth).to receive(:configured?).and_return(true)

    allow_any_instance_of(Bassinet::GoogleOAuth).to receive(:exchange)
      .and_return(Bassinet::GoogleOAuth::Identity.new(
                    sub: "google-sub-v", email: "derek@example.com",
                    email_verified: true, name: "Derek", picture: nil
                  ))

    get auth_start_path
    state = URI.decode_www_form(URI(response.headers["Location"]).query.to_s).to_h["state"]
    get auth_callback_path, params: { code: "c", state: state }

    @household = Bassinet::UserRepo.new.households_for("google-sub-v").first["household_id"]
    @child = Bassinet::ChildRepo.new(household_id: @household)
                                .create(child_id: "ch_v", name: "Mabel", timezone: "America/Chicago")
  end

  let(:repo) { Bassinet::EventRepo.new(household_id: @household) }
  let(:now_ms) { Bassinet::Dynamo::Marshal.now_ms }
  let(:zone) { ActiveSupport::TimeZone["America/Chicago"] }

  it "renders the home screen with chips, tiles and today's feed" do
    repo.create(child_id: @child.child_id, event_id: "e1", type: "diaper",
                occurred_at: now_ms, author_id: "u", payload: { "kind" => "wet" })
    repo.create(child_id: @child.child_id, event_id: "e2", type: "feed",
                occurred_at: now_ms + 1000, author_id: "u",
                payload: { "method" => "bottle", "amount_ml" => 120 })

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Wet diaper")
    expect(response.body).to include("Bottle")
    expect(response.body).to include("120 ml")
    expect(response.body).to include("action-grid")
  end

  it "renders the running-timer banner" do
    started = now_ms - 120_000
    repo.create(child_id: @child.child_id, event_id: "nap", type: "sleep",
                occurred_at: started, author_id: "u", started_at: started)

    get root_path

    expect(response.body).to include("running-banner")
    expect(response.body).to include("Stop")
  end

  it "renders the undo toast after a delete" do
    at = now_ms
    repo.create(child_id: @child.child_id, event_id: "del_me", type: "diaper",
                occurred_at: at, author_id: "u", payload: { "kind" => "dirty" })

    delete delete_child_event_path(@child.child_id, at, "del_me")
    follow_redirect!

    expect(response.body).to include("undo-toast")
    expect(response.body).to include("Undo")
  end

  it "renders the day view with navigation and filters" do
    repo.create(child_id: @child.child_id, event_id: "d1", type: "diaper",
                occurred_at: now_ms, author_id: "u", payload: { "kind" => "wet" })

    get child_day_path(@child.child_id, zone.today.to_s)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("filter-bar")
    expect(response.body).to include("Diapers")
    expect(response.body).to include("Wet diaper")
  end

  it "renders the event form for every type" do
    Bassinet::EventPayload.types.each do |type|
      get new_child_event_path(@child.child_id, type: type)
      expect(response).to have_http_status(:ok), "#{type} form failed: #{response.body[0, 300]}"
    end
  end

  it "renders the edit form for a stored event" do
    at = now_ms
    repo.create(child_id: @child.child_id, event_id: "e_edit", type: "feed",
                occurred_at: at, author_id: "u", payload: { "method" => "bottle" })

    get edit_child_event_path(@child.child_id, at, "e_edit")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Save changes")
  end
end
