require "time"

module Bassinet
  module Dynamo
    # Converts between Ruby hashes and DynamoDB's tagged attribute-value JSON,
    # in both directions.
    #
    # We deliberately do NOT use Aws::DynamoDB::AttributeValue marshalling
    # helpers: they're easy to confuse when reading responses back, and this
    # conversion is small enough to own outright. Everything is explicit.
    #
    # Supported Ruby types: String, Symbol, Integer, Float, true/false, nil,
    # Array, Hash. Date/Time are normalized to epoch-millisecond integers by
    # callers, not here — this layer stays dumb on purpose.
    module Marshal
      module_function

      def to_item(hash)
        hash.compact.each_with_object({}) do |(key, value), out|
          out[key.to_s] = to_attr(value)
        end
      end

      def to_attr(value)
        case value
        when nil        then { null: true }
        when String     then { s: value }
        when Symbol     then { s: value.to_s }
        when true       then { bool: true }
        when false      then { bool: false }
        when Integer    then { n: value.to_s }
        when Float      then { n: value.to_s }
        when Array      then { l: value.map { |v| to_attr(v) } }
        when Hash       then { m: to_item(value) }
        else
          raise ArgumentError, "unsupported attribute type #{value.class} (#{value.inspect})"
        end
      end

      def from_item(item)
        return nil if item.nil?

        item.each_with_object({}) do |(key, attr), out|
          out[key] = from_attr(attr)
        end
      end

      def from_attr(attr)
        # With the SDK's simple_attributes plugin disabled, responses come back
        # as Aws::DynamoDB::Types::AttributeValue structs rather than plain
        # hashes. Normalize to a compact hash and carry on.
        attr = normalize(attr)

        case attr
        when Hash
          if attr.key?(:null) then nil
          elsif attr.key?(:s) then attr[:s]
          elsif attr.key?(:n)
            num = attr[:n]
            # DynamoDB returns numbers as strings with no type marker. Anything
            # that isn't a clean integer round-trips as a Float.
            num.to_s.match?(/\A-?\d+\z/) ? num.to_i : num.to_f
          elsif attr.key?(:bool) then attr[:bool]
          elsif attr.key?(:l) then attr[:l].map { |v| from_attr(v) }
          elsif attr.key?(:m) then from_item(attr[:m])
          elsif attr.key?(:ss) then attr[:ss]
          elsif attr.key?(:ns) then attr[:ns].map { |n| n.to_s.match?(/\A-?\d+\z/) ? n.to_i : n.to_f }
          elsif attr.key?(:bs) then attr[:bs]
          else
            raise ArgumentError, "unrecognised DynamoDB attribute: #{attr.inspect}"
          end
        else
          raise ArgumentError, "malformed DynamoDB attribute: #{attr.inspect}"
        end
      end

      # AttributeValue struct -> compact symbol-keyed hash. Plain hashes pass
      # through unchanged so both shapes work.
      def normalize(attr)
        return attr if attr.is_a?(Hash)
        return attr unless attr.respond_to?(:to_h)

        attr.to_h.reject { |_k, v| v.nil? }
      end

      # --- helpers the repositories use -------------------------------------

      def now_ms
        (Time.current.to_f * 1000).round
      end

      def to_ms(time)
        case time
        when nil then nil
        when Integer then time
        when Time then (time.to_f * 1000).round
        when String then (Time.parse(time).to_f * 1000).round
        else raise ArgumentError, "cannot convert #{time.class} to epoch ms"
        end
      end

      def from_ms(ms)
        return nil if ms.nil?

        Time.zone ? Time.zone.at(ms / 1000.0) : Time.at(ms / 1000.0)
      end
    end
  end
end
