module Bassinet
  # DynamoDB persistence for children. Scoped to one household.
  class ChildRepo < Repo
    MAX_CHILDREN = 10

    def find(child_id)
      item = client.get(pk: Dynamo::Keys.child_pk(child_id),
                        sk: Dynamo::Keys.child_meta_sk)
      return nil if item.nil? || item["deleted_at"]
      return nil unless item["household_id"] == household_id

      hydrate(item)
    end

    def find!(child_id)
      find(child_id) || raise(Dynamo::Client::NotFound, "child #{child_id} not found")
    end

    # Live children first, archived ones after — the sort key encodes that
    # (`CHILD#<id>#0` vs `CHILD#<id>#<archived_at>`).
    def all(include_archived: false)
      items = client.query_items(
        index_name: "GSI2",
        key_condition_expression: "GSI2PK = :pk",
        expression_attribute_values: { ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.child_list_gsi2pk(household_id)) }
      )

      children = items.reject { |i| i["deleted_at"] }.map { |i| hydrate(i) }
      include_archived ? children : children.reject(&:archived?)
    end

    def create(child_id:, name:, birth_date: nil, timezone: "America/Chicago",
               units: "metric", photo_url: nil)
      if all(include_archived: true).size >= MAX_CHILDREN
        raise Dynamo::Client::ValidationFailed, "too many children in this household"
      end

      ts = now_ms
      item = {
        "PK" => Dynamo::Keys.child_pk(child_id),
        "SK" => Dynamo::Keys.child_meta_sk,
        "entity" => "child",
        "child_id" => child_id,
        "household_id" => household_id,
        "name" => name.to_s.strip,
        "birth_date" => birth_date&.to_s,
        "photo_url" => photo_url,
        "timezone" => timezone,
        "units" => units,
        "archived_at" => nil,
        "created_at" => ts,
        "updated_at" => ts,
        "deleted_at" => nil,
        "version" => 1,
        # child list index
        "GSI2PK" => Dynamo::Keys.child_list_gsi2pk(household_id),
        "GSI2SK" => Dynamo::Keys.child_list_gsi2sk(child_id, nil)
      }

      client.put(item, condition: "attribute_not_exists(PK)")
      hydrate(Dynamo::Marshal.from_item(Dynamo::Marshal.to_item(item)))
    end

    def update(child_id, changes)
      current = find!(child_id)
      allowed = %w[name birth_date timezone units photo_url archived_at]
      unknown = changes.keys.map(&:to_s) - allowed
      raise ArgumentError, "unknown child fields: #{unknown.join(', ')}" if unknown.any?

      attrs = changes.transform_keys(&:to_s)
      attrs["updated_at"] = now_ms
      attrs["version"] = current.version + 1

      archived = attrs.key?("archived_at") ? attrs["archived_at"] : current.archived_at
      attrs["GSI2SK"] = Dynamo::Keys.child_list_gsi2sk(child_id, archived)

      updated = client.update(
        pk: Dynamo::Keys.child_pk(child_id),
        sk: Dynamo::Keys.child_meta_sk,
        updates: attrs,
        condition: "version = :v",
        expression_values: { ":v" => Dynamo::Marshal.to_attr(current.version) }
      )
      hydrate(updated)
    end

    private

    def hydrate(item)
      Child.new(
        child_id: item["child_id"],
        household_id: item["household_id"],
        name: item["name"],
        birth_date: item["birth_date"],
        photo_url: item["photo_url"],
        timezone: item["timezone"],
        units: item["units"],
        archived_at: item["archived_at"],
        created_at: item["created_at"],
        updated_at: item["updated_at"],
        deleted_at: item["deleted_at"],
        version: item["version"]
      )
    end
  end
end
