module Bassinet
  module Dynamo
    # Single source of truth for the table shape. `bin/ddb-create` and the test
    # bootstrap both read this, so dev/staging/prod/test can never drift.
    #
    # Two GSIs, and only two. See docs/data-model.md for why.
    #   GSI1  CHILD#<cid>                 EVENT#<epoch>#<eid>   event timeline
    #   GSI2  HOUSEHOLD#<hid>#CHILD       CHILD#<cid>#<arch>    child list
    #         USER#<uid>                  HOUSEHOLD#<hid>       membership lookup
    module Schema
      module_function

      def definition(table_name = Tables.current)
        {
          table_name: table_name,
          billing_mode: "PAY_PER_REQUEST",
          attribute_definitions: attribute_definitions,
          key_schema: [
            { attribute_name: "PK", key_type: "HASH" },
            { attribute_name: "SK", key_type: "RANGE" }
          ],
          global_secondary_indexes: [
            {
              index_name: "GSI1",
              key_schema: [
                { attribute_name: "GSI1PK", key_type: "HASH" },
                { attribute_name: "GSI1SK", key_type: "RANGE" }
              ],
              projection: { projection_type: "ALL" }
            },
            {
              index_name: "GSI2",
              key_schema: [
                { attribute_name: "GSI2PK", key_type: "HASH" },
                { attribute_name: "GSI2SK", key_type: "RANGE" }
              ],
              projection: { projection_type: "ALL" }
            }
          ]
        }
      end

      def attribute_definitions
        %w[PK SK GSI1PK GSI1SK GSI2PK GSI2SK].map do |name|
          { attribute_name: name, attribute_type: "S" }
        end
      end

      # Production-only protections. DynamoDB Local rejects some of these, so
      # they're opt-in rather than part of `definition`.
      def production_options
        {
          deletion_protection_enabled: true,
          point_in_time_recovery_specification: { point_in_time_recovery_enabled: true }
        }
      end
    end
  end
end
