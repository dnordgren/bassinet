module Bassinet
  class Child
    attr_reader :child_id, :household_id, :name, :birth_date, :photo_url,
                :timezone, :units, :archived_at, :created_at, :updated_at,
                :deleted_at, :version

    def initialize(child_id:, household_id:, name:, birth_date: nil,
                   photo_url: nil, timezone: "America/Chicago", units: "metric",
                   archived_at: nil, created_at: nil, updated_at: nil,
                   deleted_at: nil, version: 1)
      @child_id = child_id
      @household_id = household_id
      @name = name
      @birth_date = birth_date
      @photo_url = photo_url
      @timezone = timezone
      @units = units
      @archived_at = archived_at
      @created_at = created_at
      @updated_at = updated_at
      @deleted_at = deleted_at
      @version = version
    end

    def archived? = !archived_at.nil?
    def deleted? = !deleted_at.nil?

    def age_days(now: Time.current)
      return nil if birth_date.nil?

      start = Date.parse(birth_date.to_s)
      (now.to_date - start).to_i
    end

    def as_json
      {
        "child_id" => child_id,
        "name" => name,
        "birth_date" => birth_date&.to_s,
        "photo_url" => photo_url,
        "timezone" => timezone,
        "units" => units,
        "archived_at" => archived_at,
        "created_at" => created_at,
        "updated_at" => updated_at
      }
    end
  end
end
