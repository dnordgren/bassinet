require "rails_helper"

RSpec.describe Bassinet::ChildRepo do
  let(:household_id) { "hh_#{SecureRandom.hex(6)}" }
  let(:repo) { described_class.new(household_id: household_id) }

  describe "#create" do
    it "persists a child and reads it back" do
      child = repo.create(child_id: "ch_1", name: "Mabel", birth_date: "2026-11-01")

      expect(child.name).to eq("Mabel")
      expect(child.birth_date).to eq("2026-11-01")
      expect(child.household_id).to eq(household_id)

      found = repo.find("ch_1")
      expect(found.name).to eq("Mabel")
      expect(found.timezone).to eq("America/Chicago")
      expect(found.units).to eq("metric")
    end

    it "rejects a duplicate id rather than silently overwriting" do
      repo.create(child_id: "ch_1", name: "Mabel")

      expect { repo.create(child_id: "ch_1", name: "Imposter") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "enforces the per-household cap" do
      described_class::MAX_CHILDREN.times do |i|
        repo.create(child_id: "ch_#{i}", name: "Kid #{i}")
      end

      expect { repo.create(child_id: "ch_over", name: "Too many") }
        .to raise_error(Bassinet::Dynamo::Client::ValidationFailed)
    end
  end

  describe "#all" do
    it "returns live children and hides archived ones by default" do
      repo.create(child_id: "ch_live", name: "Live")
      repo.create(child_id: "ch_arch", name: "Archived")
      repo.update("ch_arch", { archived_at: Bassinet::Dynamo::Marshal.now_ms })

      expect(repo.all.map(&:child_id)).to contain_exactly("ch_live")
      expect(repo.all(include_archived: true).map(&:child_id))
        .to contain_exactly("ch_live", "ch_arch")
    end

    it "scrolls archived children to the end of the index" do
      repo.create(child_id: "ch_a", name: "A")
      repo.create(child_id: "ch_b", name: "B")
      repo.update("ch_a", { archived_at: 1 })

      ordered = repo.all(include_archived: true).map(&:child_id)
      expect(ordered.last).to eq("ch_a")
    end
  end

  describe "#update" do
    it "bumps the version and moves the archive index key" do
      repo.create(child_id: "ch_1", name: "Mabel")
      updated = repo.update("ch_1", { name: "Mabel Rose" })

      expect(updated.name).to eq("Mabel Rose")
      expect(updated.version).to eq(2)
    end

    it "refuses unknown fields instead of writing garbage" do
      repo.create(child_id: "ch_1", name: "Mabel")
      expect { repo.update("ch_1", { evil: "x" }) }.to raise_error(ArgumentError)
    end
  end

  describe "household scoping" do
    it "cannot see another household's child" do
      other = described_class.new(household_id: "hh_other")
      other.create(child_id: "ch_theirs", name: "Theirs")

      expect(repo.find("ch_theirs")).to be_nil
      expect(repo.all).to be_empty
    end

    it "requires a household to construct" do
      expect { described_class.new(household_id: nil) }
        .to raise_error(Bassinet::Repo::ScopeError)
    end
  end
end
