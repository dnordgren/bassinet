require "rails_helper"

RSpec.describe Bassinet::HouseholdRepo do
  let(:household_id) { "hh_#{SecureRandom.hex(6)}" }
  let(:repo) { described_class.new(household_id: household_id) }

  before do
    # Braces matter: a bare hash with string keys would be parsed as keyword
    # arguments and leave `item` empty.
    Bassinet::Dynamo::Client.new.put({
      "PK" => Bassinet::Dynamo::Keys.household_pk(household_id),
      "SK" => Bassinet::Dynamo::Keys.household_meta_sk,
      "entity" => "household",
      "household_id" => household_id,
      "owner_id" => "u_owner",
      "name" => "Test"
    })
  end

  describe "#add_member!" do
    it "adds a caregiver and makes them visible to member queries" do
      repo.add_member!(user_id: "u_wife", role: "caregiver", display_name: "Wife")

      expect(repo.member?("u_wife")).to be(true)
      expect(repo.role_for("u_wife")).to eq("caregiver")
      expect(repo.owner?("u_wife")).to be(false)
    end

    it "refuses a duplicate membership instead of overwriting the role" do
      repo.add_member!(user_id: "u_wife", role: "caregiver")

      expect { repo.add_member!(user_id: "u_wife", role: "owner") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "rejects an invalid role" do
      expect { repo.add_member!(user_id: "u_x", role: "admin") }
        .to raise_error(ArgumentError)
    end

    it "enforces the member cap" do
      # MAX_MEMBERS members are allowed; the next one is refused.
      described_class::MAX_MEMBERS.times do |i|
        repo.add_member!(user_id: "u_#{i}", role: "caregiver")
      end

      expect(repo.members.size).to eq(described_class::MAX_MEMBERS)
      expect { repo.add_member!(user_id: "u_over", role: "caregiver") }
        .to raise_error(Bassinet::Dynamo::Client::ValidationFailed)
    end
  end

  describe "#remove_member!" do
    it "soft-deletes the membership and hides it from the member list" do
      repo.add_member!(user_id: "u_wife", role: "caregiver")
      repo.remove_member!("u_wife")

      expect(repo.member?("u_wife")).to be(false)
      expect(repo.members.map { |m| m["user_id"] }).not_to include("u_wife")
    end

    it "refuses to remove the owner" do
      repo.add_member!(user_id: "u_owner", role: "owner")
      expect { repo.remove_member!("u_owner") }
        .to raise_error(Bassinet::Dynamo::Client::ValidationFailed)
    end
  end

  describe "invites" do
    before { repo.add_member!(user_id: "u_owner", role: "owner") }

    it "stores only a hash of the token" do
      invite = repo.create_invite!(created_by: "u_owner")
      token = invite[:token]

      expect(token.length).to eq(described_class::INVITE_LENGTH)
      # The plaintext must not be present in the stored item.
      stored = repo.find_invite(token)
      expect(stored.values.map(&:to_s)).to all(satisfy { |v| v != token })

      expect(repo.find_invite(token)["role"]).to eq("caregiver")
    end

    it "generates tokens that are not trivially guessable or sequential" do
      tokens = 20.times.map { repo.create_invite!(created_by: "u_owner")[:token] }
      expect(tokens.uniq.size).to eq(20)
      expect(tokens.map(&:length).uniq).to eq([described_class::INVITE_LENGTH])
    end

    it "is case-insensitive on redemption" do
      invite = repo.create_invite!(created_by: "u_owner")

      expect(repo.find_invite(invite[:token].downcase)).not_to be_nil
    end

    it "can only be claimed once" do
      invite = repo.create_invite!(created_by: "u_owner")

      repo.claim_invite!(invite[:token], user_id: "u_wife")
      expect { repo.claim_invite!(invite[:token], user_id: "u_other") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses an expired invite" do
      invite = repo.create_invite!(created_by: "u_owner")
      # Force expiry into the past.
      Bassinet::Dynamo::Client.new.update(
        pk: Bassinet::Dynamo::Keys.household_pk(household_id),
        sk: Bassinet::Dynamo::Keys.invite_sk(described_class.hash_token(invite[:token])),
        updates: { "expires_at" => 1 }
      )

      expect { repo.claim_invite!(invite[:token], user_id: "u_wife") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses a claim for an unknown token" do
      expect { repo.claim_invite!("NOPE1234", user_id: "u_wife") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end
  end
end
