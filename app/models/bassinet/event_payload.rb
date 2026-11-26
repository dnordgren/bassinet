require "dry/schema"

module Bassinet
  # Per-type payload validation, SPEC.md §3.3.
  #
  # Every write goes through `validate!` before it reaches DynamoDB. The schemas
  # double as the documentation for what a tile actually sends, which is why
  # they live in code instead of prose.
  #
  # Input is a plain hash of strings (form params, or a replayed outbox body).
  # Output is a string-keyed hash with integers coerced, ready for storage.
  module EventPayload
    DIAPER = Dry::Schema.Params do
      required(:kind).filled(:string, included_in?: %w[wet dirty mixed dry])
      optional(:notes).maybe(:string, max_size?: 500)
    end

    FEED = Dry::Schema.Params do
      required(:method).filled(:string, included_in?: %w[bottle nursing solids tube])
      optional(:amount_ml).maybe(:integer, gt?: 0, lteq?: 2000)
      optional(:side).maybe(:string, included_in?: %w[left right both])
      optional(:duration_s).maybe(:integer, gt?: 0)
      optional(:foods).maybe(:array).each(:string, max_size?: 80)
      optional(:notes).maybe(:string, max_size?: 500)
    end

    SLEEP = Dry::Schema.Params do
      optional(:quality).maybe(:string, included_in?: %w[good fair poor])
      optional(:location).maybe(:string, max_size?: 80)
      optional(:notes).maybe(:string, max_size?: 500)
    end

    PUMP = Dry::Schema.Params do
      optional(:amount_ml_left).maybe(:integer, gteq?: 0, lteq?: 2000)
      optional(:amount_ml_right).maybe(:integer, gteq?: 0, lteq?: 2000)
      optional(:duration_s).maybe(:integer, gteq?: 0)
      optional(:notes).maybe(:string, max_size?: 500)
    end

    GROWTH = Dry::Schema.Params do
      optional(:weight_g).maybe(:integer, gt?: 0, lteq?: 40_000)
      optional(:height_mm).maybe(:integer, gt?: 0, lteq?: 1_500)
      optional(:head_circumference_mm).maybe(:integer, gt?: 0, lteq?: 800)
    end

    # dry-schema has no cross-field `rule` (that is dry-validation), so the
    # "at least one measurement" check is explicit here.
    GROWTH_MEASUREMENTS = %i[weight_g height_mm head_circumference_mm].freeze

    NOTE = Dry::Schema.Params do
      required(:body).filled(:string, max_size?: 2000)
    end

    SCHEMAS = {
      "diaper" => DIAPER,
      "feed" => FEED,
      "sleep" => SLEEP,
      "pump" => PUMP,
      "growth" => GROWTH,
      "note" => NOTE
    }.freeze

    module_function

    def types = SCHEMAS.keys

    # Returns a string-keyed hash. Raises ValidationFailed with a readable
    # message so the caller can put it in a toast unedited.
    def validate!(type, payload)
      schema = SCHEMAS[type.to_s]
      raise Dynamo::Client::ValidationFailed, "unknown event type: #{type.inspect}" if schema.nil?

      result = schema.call(stringify(payload) || {})
      unless result.success?
        raise Dynamo::Client::ValidationFailed, errors_text(result.errors.to_h)
      end

      validated = result.to_h.deep_stringify_keys
      require_growth_measurement!(validated) if type.to_s == "growth"
      validated
    end

    def require_growth_measurement!(validated)
      return if GROWTH_MEASUREMENTS.any? { |key| validated[key.to_s].present? }

      raise Dynamo::Client::ValidationFailed, "record at least one measurement"
    end

    def errors_text(errors)
      errors.flat_map do |field, messages|
        Array(messages).map { |m| "#{field.to_s.humanize.downcase} #{m}" }
      end.join(", ")
    end

    def stringify(payload)
      return nil if payload.nil?

      payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h.deep_stringify_keys : payload.deep_stringify_keys
    end
  end
end
