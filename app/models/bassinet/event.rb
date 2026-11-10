module Bassinet
  # Plain Ruby object. No ActiveRecord, no persistence concerns — repositories
  # own I/O. Models own identity, validation-free data shape, and behaviour.
  class Event
    TYPES = %w[diaper feed sleep pump growth note].freeze

    attr_reader :event_id, :child_id, :household_id, :type, :occurred_at,
                :started_at, :ended_at, :duration_s, :payload, :note,
                :author_id, :source, :created_at, :updated_at, :deleted_at,
                :version

    def initialize(event_id:, child_id:, household_id:, type:, occurred_at:,
                   author_id:, payload: {}, source: "web", note: nil,
                   started_at: nil, ended_at: nil, duration_s: nil,
                   created_at: nil, updated_at: nil, deleted_at: nil, version: 1)
      @event_id = event_id
      @child_id = child_id
      @household_id = household_id
      @type = type.to_s
      @occurred_at = occurred_at
      @started_at = started_at
      @ended_at = ended_at
      @duration_s = duration_s
      @payload = payload || {}
      @note = note
      @author_id = author_id
      @source = source
      @created_at = created_at
      @updated_at = updated_at
      @deleted_at = deleted_at
      @version = version
    end

    def deleted? = !deleted_at.nil?

    # A timer is "running" when it started and never stopped. Only sleep,
    # nursing feeds and pumping can be timers; the schema enforces that.
    def running?
      !deleted? && !started_at.nil? && ended_at.nil?
    end

    def to_h
      {
        event_id: event_id, child_id: child_id, household_id: household_id,
        type: type, occurred_at: occurred_at, started_at: started_at,
        ended_at: ended_at, duration_s: duration_s, payload: payload,
        note: note, author_id: author_id, source: source,
        created_at: created_at, updated_at: updated_at,
        deleted_at: deleted_at, version: version
      }
    end

    # Wire format. Kept stable on purpose — this is what /sync returns and what
    # Action Cable broadcasts, so both transports share one shape.
    def as_json
      {
        "event_id" => event_id,
        "child_id" => child_id,
        "type" => type,
        "occurred_at" => occurred_at,
        "started_at" => started_at,
        "ended_at" => ended_at,
        "duration_s" => duration_s,
        "payload" => payload,
        "note" => note,
        "author_id" => author_id,
        "created_at" => created_at,
        "updated_at" => updated_at,
        "deleted_at" => deleted_at,
        "version" => version
      }
    end
  end
end
