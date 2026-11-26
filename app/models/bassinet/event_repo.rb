module Bassinet
  # DynamoDB persistence for events. Scoped to one household.
  #
  # Two distinct clocks, on purpose:
  #   occurred_at -> when it happened, drives the sort key (the timeline)
  #   updated_at  -> when the server last accepted a change, drives delta sync
  class EventRepo < Repo
    KIND_EPOCH = "event"

    def find(child_id, event_id, occurred_at:)
      assert_child_in_scope!(child_id)
      item = client.get(
        pk: Dynamo::Keys.child_pk(child_id),
        sk: Dynamo::Keys.event_sk(occurred_at, event_id),
        consistent: true
      )
      return nil if item.nil?

      hydrate(item)
    end

    # Events between two instants, newest first. This is the day view and the
    # "what happened recently" query.
    def between(child_id, from_ms:, to_ms:, limit: 200, newest_first: true)
      assert_child_in_scope!(child_id)

      params = {
        key_condition_expression: "PK = :pk AND SK BETWEEN :lo AND :hi",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.child_pk(child_id)),
          ":lo" => Dynamo::Marshal.to_attr(Dynamo::Keys.event_sk_lower(from_ms)),
          ":hi" => Dynamo::Marshal.to_attr(Dynamo::Keys.event_sk_upper(to_ms))
        },
        limit: limit,
        scan_index_forward: !newest_first
      }

      client.query_items(params).map { |i| hydrate(i) }
    end

    def for_day(child_id, date, timezone: "UTC")
      zone = ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
      day = Date.parse(date.to_s)
      from_ms = Dynamo::Marshal.to_ms(zone.parse(day.to_s).beginning_of_day)
      to_ms = Dynamo::Marshal.to_ms(zone.parse(day.to_s).end_of_day)
      between(child_id, from_ms: from_ms, to_ms: to_ms)
    end

    # The running timer for a child, if any. Only sleep/nursing/pump can be
    # running; we look at the newest few events and filter, which is cheaper
    # than a scan and correct because a timer is always recent.
    def running(child_id)
      recent = between(child_id, from_ms: now_ms - (24 * 60 * 60 * 1000), to_ms: now_ms + 60_000, limit: 25)
      recent.find(&:running?)
    end

    # Delta sync. See docs/data-model.md §3 — for v1 this is a partition scan
    # filtered on (updated_at, event_id) tuple, which is fine at baby-tracker
    # scale. The code documents the GSI3 escape hatch.
    def changes_since(child_id, cursor:, limit: 200)
      assert_child_in_scope!(child_id)

      # +1 so the caller's cursor item is included; callers skip it by tuple.
      items = client.query_items(
        key_condition_expression: "PK = :pk",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.child_pk(child_id)),
          ":kind" => Dynamo::Marshal.to_attr(KIND_EPOCH)
        },
        filter_expression: "entity = :kind",
        limit: limit * 4   # filters run after the limit, so over-fetch
      )

      events = items.map { |i| hydrate(i) }
                    .select { |e| after_cursor?(e, cursor) }
                    .sort_by { |e| [e.updated_at, e.event_id] }

      events.first(limit)
    end

    def create(child_id:, event_id:, type:, occurred_at:, author_id:,
               payload: {}, note: nil, started_at: nil, ended_at: nil,
               duration_s: nil, source: "web")
      assert_child_in_scope!(child_id)
      ts = now_ms
      item = {
        "PK" => Dynamo::Keys.child_pk(child_id),
        "SK" => Dynamo::Keys.event_sk(occurred_at, event_id),
        "entity" => KIND_EPOCH,
        "event_id" => event_id,
        "child_id" => child_id,
        "household_id" => household_id,
        "type" => type.to_s,
        "occurred_at" => occurred_at,
        "started_at" => started_at,
        "ended_at" => ended_at,
        "duration_s" => duration_s,
        "payload" => payload || {},
        "note" => note,
        "author_id" => author_id,
        "source" => source,
        "created_at" => ts,
        "updated_at" => ts,
        "deleted_at" => nil,
        "version" => 1,
        "GSI1PK" => Dynamo::Keys.child_pk(child_id),
        "GSI1SK" => Dynamo::Keys.event_sk(occurred_at, event_id)
      }

      # The idempotency guarantee: a replayed outbox item cannot create a
      # duplicate. On collision we surface the stored item on the exception so
      # the sync layer can report `ok_replay` instead of failing the batch.
      begin
        client.put(item, condition: "attribute_not_exists(PK) AND attribute_not_exists(SK)")
      rescue Dynamo::Client::Conflict
        existing = find(child_id, event_id, occurred_at: occurred_at)
        raise Dynamo::Client::Conflict.new(
          "duplicate event #{event_id}", current: existing
        )
      end

      hydrate(Dynamo::Marshal.from_item(Dynamo::Marshal.to_item(item)))
    end

    # `base_version` is the optimistic-concurrency contract from
    # docs/sync-protocol.md §5: an offline client sends the version it edited,
    # and the write fails if the server moved on. Callers inside the app that
    # just read the record can omit it and get last-writer-wins.
    def update(child_id, event_id, occurred_at:, changes:, base_version: nil)
      current = find(child_id, event_id, occurred_at: occurred_at)
      raise Dynamo::Client::NotFound, "event #{event_id} not found" if current.nil?

      allowed = %w[payload note started_at ended_at duration_s]
      unknown = changes.keys.map(&:to_s) - allowed
      raise ArgumentError, "unknown event fields: #{unknown.join(', ')}" if unknown.any?

      expected = base_version || current.version
      if base_version && base_version != current.version
        raise Dynamo::Client::Conflict.new(
          "version conflict on #{event_id}: expected #{base_version}, found #{current.version}",
          current: current
        )
      end

      attrs = changes.transform_keys(&:to_s)
      attrs["updated_at"] = now_ms
      attrs["version"] = current.version + 1

      hydrate(client.update(
        pk: Dynamo::Keys.child_pk(child_id),
        sk: Dynamo::Keys.event_sk(occurred_at, event_id),
        updates: attrs,
        condition: "version = :v AND attribute_not_exists(deleted_at)",
        expression_values: { ":v" => Dynamo::Marshal.to_attr(expected) }
      ))
    end

    # Soft delete. Tombstones keep delta sync monotonic and stop a replayed
    # create from resurrecting a deleted event.
    def delete(child_id, event_id, occurred_at:)
      current = find(child_id, event_id, occurred_at: occurred_at)
      return nil if current.nil?

      ts = now_ms
      hydrate(client.update(
        pk: Dynamo::Keys.child_pk(child_id),
        sk: Dynamo::Keys.event_sk(occurred_at, event_id),
        updates: { "deleted_at" => ts, "updated_at" => ts, "version" => current.version + 1 },
        condition: "attribute_not_exists(deleted_at)"
      ))
    end

    # Undo of a delete. Clears the tombstone instead of recreating the row, so
    # the event keeps its identity and its place in the timeline. Guarded on the
    # tombstone still being there, so two racing undo taps can't both win.
    def restore(child_id, event_id, occurred_at:)
      assert_child_in_scope!(child_id)

      current = client.get(pk: Dynamo::Keys.child_pk(child_id),
                            sk: Dynamo::Keys.event_sk(occurred_at, event_id),
                            consistent: true)
      raise Dynamo::Client::NotFound, "event #{event_id} not found" if current.nil?

      ts = now_ms
      hydrate(client.update(
        pk: Dynamo::Keys.child_pk(child_id),
        sk: Dynamo::Keys.event_sk(occurred_at, event_id),
        updates: { "deleted_at" => nil, "updated_at" => ts,
                   "version" => current["version"].to_i + 1 },
        condition: "attribute_exists(deleted_at)"
      ))
    end

    private

    def after_cursor?(event, cursor)
      return true if cursor.nil? || cursor[:updated_at].nil?

      # Array#> does not exist in Ruby; compare tuples explicitly so the
      # (updated_at, event_id) ordering is total and stable.
      ([
        event.updated_at,
        event.event_id.to_s
      ] <=> [
        cursor[:updated_at],
        cursor[:event_id].to_s
      ]) == 1
    end

    def hydrate(item)
      Event.new(
        event_id: item["event_id"],
        child_id: item["child_id"],
        household_id: item["household_id"],
        type: item["type"],
        occurred_at: item["occurred_at"],
        started_at: item["started_at"],
        ended_at: item["ended_at"],
        duration_s: item["duration_s"],
        payload: item["payload"] || {},
        note: item["note"],
        author_id: item["author_id"],
        source: item["source"],
        created_at: item["created_at"],
        updated_at: item["updated_at"],
        deleted_at: item["deleted_at"],
        version: item["version"]
      )
    end
  end
end
