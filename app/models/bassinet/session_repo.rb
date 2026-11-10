module Bassinet
  # Server-side session records.
  #
  # The cookie is signed and encrypted, but it is not the source of truth: it
  # carries a session id, and this repo holds the record. That is what makes
  # "sign out everywhere" real instead of theatre — delete the rows and every
  # cookie pointing at them stops working on its next request.
  class SessionRepo
    TTL_MS = 90 * 24 * 60 * 60 * 1000

    attr_reader :client

    def initialize(client: nil)
      @client = client || Dynamo::Client.new
    end

    def create(user_id:, household_id:, user_agent: nil, ip: nil)
      session_id = SecureRandom.uuid
      now = Dynamo::Marshal.now_ms

      client.put({
        "PK" => Dynamo::Keys.user_pk(user_id),
        "SK" => Dynamo::Keys.user_session_sk(session_id),
        "entity" => "session",
        "session_id" => session_id,
        "user_id" => user_id,
        "household_id" => household_id,
        "created_at" => now,
        "last_seen_at" => now,
        "expires_at" => now + TTL_MS,
        "user_agent" => user_agent,
        "ip" => ip,
        "revoked_at" => nil
      })

      session_id
    end

    # Returns the session record, or nil if missing, revoked or expired.
    # Expiry is checked here rather than relying on DynamoDB TTL, which can lag
    # by up to 48 hours and must never be trusted for authorization.
    def find(user_id, session_id)
      return nil if user_id.blank? || session_id.blank?

      item = client.get(pk: Dynamo::Keys.user_pk(user_id),
                        sk: Dynamo::Keys.user_session_sk(session_id),
                        consistent: true)
      return nil if item.nil?
      return nil if item["revoked_at"]
      return nil if item["expires_at"].to_i <= Dynamo::Marshal.now_ms

      item
    end

    def touch(user_id, session_id)
      client.update(
        pk: Dynamo::Keys.user_pk(user_id),
        sk: Dynamo::Keys.user_session_sk(session_id),
        updates: { "last_seen_at" => Dynamo::Marshal.now_ms },
        # Without this, update_item would fabricate a session row for any
        # (user_id, session_id) pair it was handed.
        require_existing: true
      )
    rescue Dynamo::Client::Error, Dynamo::Client::Conflict, Dynamo::Client::NotFound
      # A failed touch must never break a valid request.
      nil
    end

    def revoke(user_id, session_id)
      client.update(
        pk: Dynamo::Keys.user_pk(user_id),
        sk: Dynamo::Keys.user_session_sk(session_id),
        updates: { "revoked_at" => Dynamo::Marshal.now_ms },
        require_existing: true
      )
      true
    rescue Dynamo::Client::Conflict, Dynamo::Client::NotFound
      false
    end

    def revoke_all(user_id)
      sessions = client.query_items(
        key_condition_expression: "PK = :pk AND begins_with(SK, :s)",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.user_pk(user_id)),
          ":s" => Dynamo::Marshal.to_attr("SESSION#")
        }
      ).reject { |i| i["revoked_at"] }

      now = Dynamo::Marshal.now_ms
      sessions.each do |item|
        client.update(
          pk: item["PK"],
          sk: item["SK"],
          updates: { "revoked_at" => now }
        )
      end

      sessions.size
    end

    def active_for(user_id)
      client.query_items(
        key_condition_expression: "PK = :pk AND begins_with(SK, :s)",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.user_pk(user_id)),
          ":s" => Dynamo::Marshal.to_attr("SESSION#")
        }
      ).select { |i| i["revoked_at"].nil? && i["expires_at"].to_i > Dynamo::Marshal.now_ms }
    end
  end
end
