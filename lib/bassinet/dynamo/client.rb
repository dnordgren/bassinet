require "aws-sdk-dynamodb"

module Bassinet
  module Dynamo
    # Thin, explicit wrapper over the DynamoDB client. No ORM, no magic.
    #
    # Two rules this class exists to enforce:
    #   1. Every call is scoped by a partition key the caller must supply.
    #   2. Errors are normalized so callers can distinguish "someone else got
    #      there first" (conditional failure) from "the table is gone" from
    #      "you sent garbage".
    class Client
      class Error < StandardError; end
      class NotFound < Error; end
      class Conflict < Error
        attr_reader :current

        def initialize(message = "conditional check failed", current: nil)
          super(message)
          @current = current
        end
      end
      class ValidationFailed < Error; end

      attr_reader :table

      def initialize(table: Tables.current, client: nil)
        @table = table
        @client = client || Aws::DynamoDB::Client.new
      end

      def raw = @client

      # --- single item ------------------------------------------------------

      def get(pk:, sk:, consistent: false)
        response = @client.get_item(
          table_name: table,
          key: Marshal.to_item("PK" => pk, "SK" => sk),
          consistent_read: consistent
        )
        response.item ? Marshal.from_item(response.item) : nil
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      def get!(pk:, sk:, consistent: false)
        get(pk: pk, sk: sk, consistent: consistent) ||
          raise(NotFound, "no item at #{pk} / #{sk}")
      end

      # `condition: nil` means unconditional. Pass an expression to make the
      # write safe against races — this is how events become idempotent.
      def put(item, condition: nil, expression_values: nil)
        params = {
          table_name: table,
          item: Marshal.to_item(item)
        }
        if condition
          params[:condition_expression] = condition
          params[:expression_attribute_values] = expression_values if expression_values
        end
        @client.put_item(params)
        item
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException => e
        raise Conflict, e.message
      rescue Aws::DynamoDB::Errors::ValidationException => e
        raise ValidationFailed, e.message
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      def delete(pk:, sk:, condition: nil, expression_values: nil)
        params = {
          table_name: table,
          key: Marshal.to_item("PK" => pk, "SK" => sk)
        }
        if condition
          params[:condition_expression] = condition
          params[:expression_attribute_values] = expression_values
        end
        @client.delete_item(params)
        true
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException => e
        raise Conflict, e.message
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      def update(pk:, sk:, updates:, condition: nil, expression_values: nil)
        names = {}
        values = (expression_values || {}).dup
        sets = []

        updates.each_with_index do |(field, value), i|
          name_key = "#n#{i}"
          value_key = ":v#{i}"
          names[name_key] = field.to_s
          values[value_key] = Marshal.to_attr(value)
          sets << "#{name_key} = #{value_key}"
        end
        raise ArgumentError, "no updates supplied" if sets.empty?

        params = {
          table_name: table,
          key: Marshal.to_item("PK" => pk, "SK" => sk),
          update_expression: "SET #{sets.join(', ')}",
          expression_attribute_names: names,
          expression_attribute_values: values,
          return_values: "ALL_NEW"
        }
        if condition
          params[:condition_expression] = condition
        end

        response = @client.update_item(params)
        Marshal.from_item(response.attributes)
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException => e
        raise Conflict, e.message
      rescue Aws::DynamoDB::Errors::ValidationException => e
        raise ValidationFailed, e.message
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      # --- queries ----------------------------------------------------------

      # Yields pages of Ruby hashes. Callers get a plain enumerator and never
      # see DynamoDB pagination tokens.
      def query_raw(params)
        Enumerator.new do |yielder|
          last_key = nil
          loop do
            page = params.merge(table_name: table)
            page[:exclusive_start_key] = last_key if last_key
            response = @client.query(page)
            yielder << response.items.map { |i| Marshal.from_item(i) }
            last_key = response.last_evaluated_key
            break if last_key.nil? || last_key.empty?
          end
        end
      end

      def query_items(params)
        query_raw(params).flat_map { |page| page }
      end

      def scan_items(params = {})
        Enumerator.new do |yielder|
          last_key = nil
          loop do
            page = params.merge(table_name: table)
            page[:exclusive_start_key] = last_key if last_key
            response = @client.scan(page)
            yielder << response.items.map { |i| Marshal.from_item(i) }
            last_key = response.last_evaluated_key
            break if last_key.nil? || last_key.empty?
          end
        end.flat_map { |page| page }
      end

      # --- transactions & batches -------------------------------------------

      def transact_write(puts: [], deletes: [])
        items = []
        puts.each do |entry|
          items << { put: { table_name: table, item: Marshal.to_item(entry[:item]) } }
        end
        deletes.each do |entry|
          items << {
            delete: { table_name: table, key: Marshal.to_item("PK" => entry[:pk], "SK" => entry[:sk]) }
          }
        end
        raise ArgumentError, "transaction needs at least one action" if items.empty?
        raise ArgumentError, "transaction supports at most 100 actions" if items.size > 100

        @client.transact_write_items(transact_items: items)
        true
      rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
        raise Conflict, e.message
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      def batch_write(puts: [], deletes: [])
        puts.each_slice(25) do |slice|
          requests = slice.map { |item| { put_request: { item: Marshal.to_item(item) } } }
          @client.batch_write_item(request_items: { table => requests })
        end
        deletes.each_slice(25) do |slice|
          requests = slice.map { |(pk, sk)| { delete_request: { key: Marshal.to_item("PK" => pk, "SK" => sk) } } }
          @client.batch_write_item(request_items: { table => requests })
        end
        true
      rescue Aws::DynamoDB::Errors::ServiceError => e
        raise translate(e)
      end

      private

      def translate(error)
        case error
        when Aws::DynamoDB::Errors::ResourceNotFoundException
          Error.new("table #{table} does not exist")
        when Aws::DynamoDB::Errors::ValidationException
          ValidationFailed.new(error.message)
        else
          Error.new("#{error.class}: #{error.message}")
        end
      end
    end
  end
end
