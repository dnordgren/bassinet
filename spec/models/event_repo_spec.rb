require "rails_helper"

RSpec.describe Bassinet::EventRepo do
  let(:household_id) { "hh_#{SecureRandom.hex(6)}" }
  let(:child_repo) { Bassinet::ChildRepo.new(household_id: household_id) }
  let(:repo) { described_class.new(household_id: household_id) }
  let(:child_id) { "ch_#{SecureRandom.hex(4)}" }

  before { child_repo.create(child_id: child_id, name: "Mabel") }

  def create_diaper(event_id: SecureRandom.uuid, at: Bassinet::Dynamo::Marshal.now_ms,
                    kind: "wet", author: "u_1")
    repo.create(
      child_id: child_id, event_id: event_id, type: "diaper",
      occurred_at: at, author_id: author, payload: { "kind" => kind }
    )
  end

  # Server-stamped updated_at can't be controlled through the repo, so tests
  # that assert sync ordering pin it directly.
  def force_updated_at(event_id, updated_at, at:)
    Bassinet::Dynamo::Client.new.update(
      pk: Bassinet::Dynamo::Keys.child_pk(child_id),
      sk: Bassinet::Dynamo::Keys.event_sk(at, event_id),
      updates: { "updated_at" => updated_at }
    )
  end

  describe "#create" do
    it "persists an event and reads it back by id and timestamp" do
      at = 1_762_699_000_000
      event = create_diaper(event_id: "evt_1", at: at, kind: "mixed")

      found = repo.find(child_id, "evt_1", occurred_at: at)
      expect(found.event_id).to eq("evt_1")
      expect(found.type).to eq("diaper")
      expect(found.payload).to eq("kind" => "mixed")
      expect(found.note).to be_nil
      expect(found.deleted?).to be(false)
    end

    it "bumps no version on create and starts at 1" do
      expect(create_diaper.event_id).to be_present
      expect(repo.between(child_id, from_ms: 0, to_ms: 9_999_999_999_999).first.version).to eq(1)
    end

    # This is the guarantee the whole offline design rests on: a replayed
    # outbox item must never produce a second row.
    it "raises Conflict carrying the stored item on a replay" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_dup", at: at, kind: "wet")

      expect { create_diaper(event_id: "evt_dup", at: at, kind: "dirty") }
        .to raise_error(Bassinet::Dynamo::Client::Conflict) { |error|
          expect(error.current).to be_a(Bassinet::Event)
          expect(error.current.payload).to eq("kind" => "wet")
        }
    end

    it "leaves exactly one row after three replays" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_3x", at: at)

      3.times do
        begin
          create_diaper(event_id: "evt_3x", at: at)
        rescue Bassinet::Dynamo::Client::Conflict
          nil
        end
      end

      expect(repo.between(child_id, from_ms: 0, to_ms: 9_999_999_999_999).size).to eq(1)
    end
  end

  describe "#between" do
    it "returns only events inside the window" do
      create_diaper(event_id: "old", at: 1_000)
      create_diaper(event_id: "new", at: 5_000)

      rows = repo.between(child_id, from_ms: 4_000, to_ms: 6_000)
      expect(rows.map(&:event_id)).to contain_exactly("new")
    end

    it "orders newest first by default and oldest first when asked" do
      create_diaper(event_id: "a", at: 1_000)
      create_diaper(event_id: "b", at: 2_000)

      expect(repo.between(child_id, from_ms: 0, to_ms: 9_999).map(&:event_id)).to eq(%w[b a])
      expect(repo.between(child_id, from_ms: 0, to_ms: 9_999, newest_first: false).map(&:event_id)).to eq(%w[a b])
    end

    it "is exclusive of other children" do
      other_child = "ch_other_#{SecureRandom.hex(3)}"
      child_repo.create(child_id: other_child, name: "Other")
      other_repo = described_class.new(household_id: household_id)
      other_repo.create(child_id: other_child, event_id: "theirs", type: "note",
                        occurred_at: 1_000, author_id: "u_1", payload: { "body" => "hi" })

      expect(repo.between(child_id, from_ms: 0, to_ms: 9_999)).to be_empty
    end
  end

  describe "#for_day" do
    it "uses the child's timezone, not UTC" do
      # 2026-11-09 23:30 in Chicago is 2026-11-10 05:30 UTC. It must land on
      # the 9th, not the 10th.
      zone = ActiveSupport::TimeZone["America/Chicago"]
      at = Bassinet::Dynamo::Marshal.to_ms(zone.parse("2026-11-09 23:30:00"))
      create_diaper(event_id: "late", at: at)

      expect(repo.for_day(child_id, "2026-11-09", timezone: "America/Chicago").map(&:event_id))
        .to contain_exactly("late")
      expect(repo.for_day(child_id, "2026-11-10", timezone: "America/Chicago")).to be_empty
    end
  end

  describe "#running" do
    it "finds a started, unfinished sleep" do
      at = Bassinet::Dynamo::Marshal.now_ms - 60_000
      repo.create(child_id: child_id, event_id: "nap", type: "sleep",
                  occurred_at: at, author_id: "u_1", started_at: at)

      expect(repo.running(child_id).event_id).to eq("nap")
    end

    it "ignores a timer that has been stopped" do
      at = Bassinet::Dynamo::Marshal.now_ms - 60_000
      repo.create(child_id: child_id, event_id: "nap", type: "sleep",
                  occurred_at: at, author_id: "u_1", started_at: at,
                  ended_at: at + 30_000, duration_s: 30)

      expect(repo.running(child_id)).to be_nil
    end

    it "returns nil when nothing is running" do
      create_diaper
      expect(repo.running(child_id)).to be_nil
    end
  end

  describe "#update" do
    it "bumps version and applies the patch" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_u", at: at, kind: "wet")

      updated = repo.update(child_id, "evt_u", occurred_at: at, changes: { payload: { "kind" => "mixed" } })
      expect(updated.payload).to eq("kind" => "mixed")
      expect(updated.version).to eq(2)
    end

    it "rejects unknown fields" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_x", at: at)
      expect { repo.update(child_id, "evt_x", occurred_at: at, changes: { occurred_at: 5 }) }
        .to raise_error(ArgumentError)
    end

    it "reports a version conflict when the client's base_version is stale" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_c", at: at)          # version 1
      repo.update(child_id, "evt_c", occurred_at: at, changes: { note: "theirs" })  # version 2

      # The offline client still believes it is editing version 1.
      expect do
        repo.update(child_id, "evt_c", occurred_at: at,
                    changes: { note: "mine" }, base_version: 1)
      end.to raise_error(Bassinet::Dynamo::Client::Conflict) { |error|
        expect(error.current.version).to eq(2)
        expect(error.current.note).to eq("theirs")
      }
    end

    it "allows a caller with no base_version to write last-writer-wins" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_lww", at: at)
      repo.update(child_id, "evt_lww", occurred_at: at, changes: { note: "theirs" })

      updated = repo.update(child_id, "evt_lww", occurred_at: at, changes: { note: "mine" })
      expect(updated.note).to eq("mine")
      expect(updated.version).to eq(3)
    end
  end

  describe "#delete" do
    it "writes a tombstone instead of removing the row" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_d", at: at)

      deleted = repo.delete(child_id, "evt_d", occurred_at: at)
      expect(deleted.deleted?).to be(true)

      # Still physically present, so a replayed create cannot resurrect it.
      still_there = repo.find(child_id, "evt_d", occurred_at: at)
      expect(still_there).not_to be_nil
      expect(still_there.deleted?).to be(true)
    end

    it "is idempotent" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_i", at: at)
      repo.delete(child_id, "evt_i", occurred_at: at)

      expect { repo.delete(child_id, "evt_i", occurred_at: at) }
        .to raise_error(Bassinet::Dynamo::Client::Conflict)
    end
  end

  describe "#changes_since" do
    it "returns everything on a nil cursor" do
      create_diaper(event_id: "a", at: 1_000)
      create_diaper(event_id: "b", at: 2_000)

      expect(repo.changes_since(child_id, cursor: nil).map(&:event_id))
        .to contain_exactly("a", "b")
    end

    it "excludes the cursor item so a resumed sync never double-applies it" do
      create_diaper(event_id: "a", at: 1_000)
      b = create_diaper(event_id: "b", at: 2_000)

      cursor = { updated_at: b.updated_at, event_id: b.event_id }
      expect(repo.changes_since(child_id, cursor: cursor).map(&:event_id)).to eq([])
    end

    it "reports updates after the cursor, ordered by updated_at" do
      create_diaper(event_id: "a", at: 1_000)
      create_diaper(event_id: "b", at: 2_000)

      # updated_at is stamped server-side in milliseconds, so two creates can
      # land in the same millisecond. Pin them here to make the ordering
      # assertion deterministic instead of racing the clock.
      force_updated_at("a", 1_000, at: 1_000)
      force_updated_at("b", 2_000, at: 2_000)

      changed = repo.changes_since(child_id, cursor: { updated_at: 1_500, event_id: "zzz" })
      expect(changed.map(&:event_id)).to eq(%w[b])
    end

    it "returns changes in (updated_at, event_id) order" do
      create_diaper(event_id: "zz", at: 1_000)
      create_diaper(event_id: "aa", at: 2_000)
      force_updated_at("zz", 5_000, at: 1_000)
      force_updated_at("aa", 5_000, at: 2_000)

      # Same instant: the event id breaks the tie, which is what makes a
      # cursor resumable mid-millisecond.
      changed = repo.changes_since(child_id, cursor: nil)
      expect(changed.map(&:event_id)).to eq(%w[aa zz])
    end

    it "reports tombstones so deletions propagate" do
      a = create_diaper(event_id: "gone", at: 1_000)
      cursor = { updated_at: a.updated_at - 1, event_id: "before" }
      repo.delete(child_id, "gone", occurred_at: 1_000)

      changed = repo.changes_since(child_id, cursor: cursor)
      expect(changed.map(&:event_id)).to eq(%w[gone])
      expect(changed.first.deleted?).to be(true)
    end
  end

  describe "household scoping" do
    it "refuses to read a child belonging to another household" do
      intruder = described_class.new(household_id: "hh_intruder")

      expect { intruder.between(child_id, from_ms: 0, to_ms: 9_999) }
        .to raise_error(Bassinet::Repo::ScopeError)
    end

    it "refuses to write to a child belonging to another household" do
      intruder = described_class.new(household_id: "hh_intruder")

      expect do
        intruder.create(child_id: child_id, event_id: "sneaky", type: "note",
                        occurred_at: 1_000, author_id: "u_evil", payload: { "body" => "x" })
      end.to raise_error(Bassinet::Repo::ScopeError)
    end

    it "refuses a cross-household update and delete" do
      at = 1_762_699_000_000
      create_diaper(event_id: "evt_z", at: at)
      intruder = described_class.new(household_id: "hh_intruder")

      expect { intruder.update(child_id, "evt_z", occurred_at: at, changes: { note: "x" }) }
        .to raise_error(Bassinet::Repo::ScopeError)
      expect { intruder.delete(child_id, "evt_z", occurred_at: at) }
        .to raise_error(Bassinet::Repo::ScopeError)
    end

    it "reports a missing child as NotFound rather than a scope error" do
      expect { repo.between("ch_nonexistent", from_ms: 0, to_ms: 9_999) }
        .to raise_error(Bassinet::Dynamo::Client::NotFound)
    end
  end
end
