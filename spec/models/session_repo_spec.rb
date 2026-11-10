require "rails_helper"

RSpec.describe Bassinet::SessionRepo do
  let(:repo) { described_class.new }
  let(:user_id) { "u_#{SecureRandom.hex(4)}" }
  let(:household_id) { "hh_#{SecureRandom.hex(4)}" }

  describe "#create / #find" do
    it "round-trips a live session" do
      session_id = repo.create(user_id: user_id, household_id: household_id, user_agent: "Safari")

      found = repo.find(user_id, session_id)
      expect(found["user_id"]).to eq(user_id)
      expect(found["household_id"]).to eq(household_id)
      expect(found["user_agent"]).to eq("Safari")
    end

    it "returns nil for a session belonging to a different user" do
      session_id = repo.create(user_id: user_id, household_id: household_id)

      # The session id alone must be worthless without the matching user id,
      # because the id is the sort key under USER#<id>.
      expect(repo.find("someone_else", session_id)).to be_nil
    end

    it "returns nil for blank inputs instead of querying" do
      expect(repo.find(nil, "x")).to be_nil
      expect(repo.find(user_id, "")).to be_nil
    end
  end

  describe "expiry" do
    it "treats an expired session as absent even if the row still exists" do
      session_id = repo.create(user_id: user_id, household_id: household_id)
      Bassinet::Dynamo::Client.new.update(
        pk: Bassinet::Dynamo::Keys.user_pk(user_id),
        sk: Bassinet::Dynamo::Keys.user_session_sk(session_id),
        updates: { "expires_at" => Bassinet::Dynamo::Marshal.now_ms - 1 }
      )

      # DynamoDB TTL can lag by 48h, so authorization must check the timestamp
      # itself rather than trusting row absence.
      expect(repo.find(user_id, session_id)).to be_nil
    end
  end

  describe "#revoke" do
    it "kills one session and leaves the others alone" do
      keep = repo.create(user_id: user_id, household_id: household_id)
      kill = repo.create(user_id: user_id, household_id: household_id)

      repo.revoke(user_id, kill)

      expect(repo.find(user_id, kill)).to be_nil
      expect(repo.find(user_id, keep)).not_to be_nil
    end
  end

  describe "#revoke_all" do
    it "logs out every device" do
      3.times { repo.create(user_id: user_id, household_id: household_id) }

      expect(repo.revoke_all(user_id)).to eq(3)
      expect(repo.active_for(user_id)).to be_empty
    end
  end

  describe "#touch" do
    it "updates last_seen_at without breaking the session" do
      session_id = repo.create(user_id: user_id, household_id: household_id)
      before = repo.find(user_id, session_id)["last_seen_at"]
      sleep 0.01

      repo.touch(user_id, session_id)

      after = repo.find(user_id, session_id)["last_seen_at"]
      expect(after).to be > before
      expect(repo.find(user_id, session_id)).not_to be_nil
    end

    it "swallows errors so a failed touch never breaks a request" do
      expect(repo.touch("ghost", "nothing")).to be_nil
    end
  end
end
