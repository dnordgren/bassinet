require "rails_helper"

RSpec.describe Bassinet::HandoffRepo do
  let(:repo) { described_class.new }

  describe "#create" do
    it "returns a short code and a long poll id" do
      handoff = repo.create

      expect(handoff[:code].length).to eq(described_class::CODE_LENGTH)
      expect(handoff[:poll_id].length).to be >= 24
      expect(handoff[:expires_at]).to be > Bassinet::Dynamo::Marshal.now_ms
    end

    it "uses an alphabet without lookalike characters" do
      letters = 50.times.map { repo.create[:code] }.join.chars.uniq

      # No I, L, O or U — the ones people misread when typing a code off a screen.
      expect(letters).not_to include("I", "L", "O", "U")
    end

    it "stores neither the plaintext code nor the plaintext poll id" do
      handoff = repo.create
      stored = repo.find_by_code(handoff[:code])
      flattened = stored.values.map(&:to_s)

      expect(flattened).not_to include(handoff[:code])
      expect(flattened).not_to include(handoff[:poll_id])
    end

    it "makes the handoff findable by poll id without a scan" do
      handoff = repo.create
      found = repo.find_by_poll_id(handoff[:poll_id])

      expect(found["code_hash"]).to eq(described_class.hash_value(handoff[:code]))
    end

    it "returns nil for unknown codes and poll ids" do
      expect(repo.find_by_code("ZZZZZZ")).to be_nil
      expect(repo.find_by_poll_id("nope")).to be_nil
    end

    it "generates unique codes and poll ids" do
      handoffs = 20.times.map { repo.create }

      expect(handoffs.map { |h| h[:code] }.uniq.size).to eq(20)
      expect(handoffs.map { |h| h[:poll_id] }.uniq.size).to eq(20)
    end
  end

  describe "#claim!" do
    it "records the user and marks the handoff claimed" do
      handoff = repo.create
      repo.claim!(handoff[:code], user_id: "u_1")

      expect(repo.find_by_code(handoff[:code])["status"]).to eq("claimed")
      expect(repo.find_by_code(handoff[:code])["user_id"]).to eq("u_1")
    end

    it "cannot be claimed twice" do
      handoff = repo.create
      repo.claim!(handoff[:code], user_id: "u_1")

      expect { repo.claim!(handoff[:code], user_id: "u_2") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses an expired handoff" do
      handoff = repo.create
      Bassinet::Dynamo::Client.new.update(
        pk: "HANDOFF##{described_class.hash_value(handoff[:code])}",
        sk: "META",
        updates: { "expires_at" => 1 }
      )

      expect { repo.claim!(handoff[:code], user_id: "u_1") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses an unknown code" do
      expect { repo.claim!("AAAAAA", user_id: "u_1") }
        .to raise_error(Bassinet::Dynamo::Client::NotFound)
    end
  end

  describe "#redeem!" do
    it "returns the user and burns the handoff" do
      handoff = repo.create
      repo.claim!(handoff[:code], user_id: "u_9")

      expect(repo.redeem!(handoff[:poll_id])).to eq("u_9")
      expect(repo.find_by_code(handoff[:code])["status"]).to eq("consumed")
    end

    it "cannot be redeemed twice" do
      handoff = repo.create
      repo.claim!(handoff[:code], user_id: "u_9")
      repo.redeem!(handoff[:poll_id])

      expect { repo.redeem!(handoff[:poll_id]) }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses to redeem an unclaimed handoff" do
      handoff = repo.create
      expect { repo.redeem!(handoff[:poll_id]) }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end

    it "refuses an unknown poll id" do
      expect { repo.redeem!("nope") }
        .to raise_error(Bassinet::Dynamo::Client::NotFound)
    end
  end

  describe "#status_for_poll" do
    it "reports waiting, then claimed, then consumed" do
      handoff = repo.create
      expect(repo.status_for_poll(handoff[:poll_id])).to eq(:waiting)

      repo.claim!(handoff[:code], user_id: "u_1")
      expect(repo.status_for_poll(handoff[:poll_id])).to eq(:claimed)

      repo.redeem!(handoff[:poll_id])
      expect(repo.status_for_poll(handoff[:poll_id])).to eq(:consumed)
    end

    it "reports expired and unknown" do
      handoff = repo.create
      Bassinet::Dynamo::Client.new.update(
        pk: "HANDOFF##{described_class.hash_value(handoff[:code])}",
        sk: "META",
        updates: { "expires_at" => 1 }
      )

      expect(repo.status_for_poll(handoff[:poll_id])).to eq(:expired)
      expect(repo.status_for_poll("nope")).to eq(:unknown)
    end
  end
end
