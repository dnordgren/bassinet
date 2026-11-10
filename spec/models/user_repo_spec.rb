require "rails_helper"

RSpec.describe Bassinet::UserRepo do
  let(:repo) { described_class.new }

  describe "#provision!" do
    it "creates the user, email index, household and owner member in one go" do
      result = repo.provision!(
        user_id: "google-sub-1",
        email: "Derek@Example.com ",
        name: "Derek Nordgren",
        avatar_url: "https://example.com/a.png"
      )

      user = result[:user]
      expect(user.user_id).to eq("google-sub-1")
      expect(user.email).to eq("derek@example.com")   # normalized
      expect(user.display_name).to eq("Derek Nordgren")

      household_id = result[:household_id]
      household = Bassinet::HouseholdRepo.new(household_id: household_id)
      members = household.members

      expect(members.size).to eq(1)
      expect(members.first["role"]).to eq("owner")
      expect(members.first["user_id"]).to eq("google-sub-1")
    end

    it "makes the user findable by email" do
      repo.provision!(user_id: "sub-2", email: "wife@example.com", name: "Wife")

      found = repo.find_by_email("WIFE@example.com")
      expect(found.user_id).to eq("sub-2")
    end

    it "records the household on the user's GSI2 so login can list households" do
      result = repo.provision!(user_id: "sub-3", email: "a@b.c")

      households = repo.households_for("sub-3")
      expect(households.size).to eq(1)
      expect(households.first["household_id"]).to eq(result[:household_id])
    end

    it "is atomic: a failure leaves no orphaned member" do
      allow_any_instance_of(Bassinet::Dynamo::Client).to receive(:transact_write)
        .and_raise(Bassinet::Dynamo::Client::Error, "boom")

      expect { repo.provision!(user_id: "sub-4", email: "x@y.z") }
        .to raise_error(Bassinet::Dynamo::Client::Error)

      expect(repo.find("sub-4")).to be_nil
      expect(repo.find_by_email("x@y.z")).to be_nil
    end
  end

  describe "#find" do
    it "returns nil for an unknown user" do
      expect(repo.find("nobody")).to be_nil
    end
  end

  describe "#refresh_profile" do
    before { repo.provision!(user_id: "sub-5", email: "old@example.com", name: "Old Name") }

    it "updates display fields when the provider reports a change" do
      updated = repo.refresh_profile("sub-5", name: "New Name", avatar_url: "https://x/y.png")

      expect(updated.name).to eq("New Name")
      expect(updated.avatar_url).to eq("https://x/y.png")
      expect(updated.email).to eq("old@example.com")
    end

    it "does not write when nothing changed" do
      before_ts = repo.find("sub-5").updated_at
      sleep 0.01
      repo.refresh_profile("sub-5", name: "Old Name")

      expect(repo.find("sub-5").updated_at).to eq(before_ts)
    end

    it "returns nil for an unknown user instead of creating a stray row" do
      expect(repo.refresh_profile("ghost", name: "x")).to be_nil
    end
  end

  describe Bassinet::User do
    it "falls back to the email local part for a missing name" do
      user = described_class.new(user_id: "u", email: "derek@example.com")
      expect(user.display_name).to eq("derek")
    end

    it "builds initials from a name" do
      user = described_class.new(user_id: "u", email: "a@b.c", name: "Derek Nordgren")
      expect(user.initials).to eq("DN")
    end
  end
end
