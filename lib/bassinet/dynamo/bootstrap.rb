require "aws-sdk-dynamodb"

module Bassinet
  module Dynamo
    # Creates / deletes the table. Used by `bin/ddb-create`, and by the test
    # bootstrap so every spec run starts from a known-good table.
    module Bootstrap
      module_function

      # Idempotent: safe to run on every boot.
      def ensure_table!(table: Tables.current, production: false, client: nil)
        client ||= Aws::DynamoDB::Client.new

        return table if exists?(table: table, client: client)

        params = Schema.definition(table)
        params.merge!(Schema.production_options) if production

        client.create_table(params)
        wait_until(:table_exists, table, client)

        table
      rescue Aws::DynamoDB::Errors::ResourceInUseException
        # Another process won the race. That's fine; the table is there now.
        table
      end

      def exists?(table: Tables.current, client: nil)
        client ||= Aws::DynamoDB::Client.new
        client.describe_table(table_name: table)
        true
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        false
      end

      def delete_table!(table: Tables.current, client: nil)
        client ||= Aws::DynamoDB::Client.new
        client.delete_table(table_name: table)
        wait_until(:table_not_exists, table, client)
        true
      rescue Aws::DynamoDB::Errors::ResourceNotFoundException
        true
      end

      # Test-only: nuke and recreate. Cheap under -sharedDb.
      def reset!(table: Tables.current)
        delete_table!(table: table)
        ensure_table!(table: table)
      end

      # The SDK waiter takes its tuning on the waiter object, not on #wait —
      # passing delay/max_attempts to #wait raises ArgumentError. Keep this in
      # one place so it can't regress.
      def wait_until(name, table, client)
        case name
        when :table_exists
          Aws::DynamoDB::Waiters::TableExists.new(
            client: client, delay: 0.5, max_attempts: 60, interval: 0.5
          ).wait(table_name: table)
        when :table_not_exists
          Aws::DynamoDB::Waiters::TableNotExists.new(
            client: client, delay: 0.5, max_attempts: 60, interval: 0.5
          ).wait(table_name: table)
        else
          raise ArgumentError, "unknown waiter #{name}"
        end
      end
    end
  end
end
