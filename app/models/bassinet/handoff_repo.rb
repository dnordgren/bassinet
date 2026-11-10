module Bassinet
  # The iOS standalone sign-in handoff, per docs/auth.md §2.
  #
  # Google refuses OAuth inside an installed iOS home-screen app, and that app
  # has its own cookie jar anyway. So: the app mints a code, sends the user to
  # Safari, Safari completes OAuth, and the app polls until it can claim a
  # session.
  #
  # What protects the claim:
  #   * the poll id is 128 bits of randomness, held only in an HttpOnly,
  #     encrypted, SameSite cookie in the app's own browser
  #   * the handoff must be *claimed* — i.e. someone actually completed Google
  #     OAuth in Safari — before it yields anything
  #   * it is single-use and expires in 10 minutes
  #
  # An earlier draft had Safari mint a separate session token, but the app has
  # no channel to receive a plaintext value except the same poll it is already
  # trusted with, so that added moving parts without adding protection. The
  # poll id is the bearer; keep it heavily guarded instead of pretending
  # otherwise.
  class HandoffRepo
    TTL_MS = 10 * 60 * 1000
    CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ".chars.freeze
    CODE_LENGTH = 6

    STATUS_CREATED = "created".freeze
    STATUS_CLAIMED = "claimed".freeze
    STATUS_CONSUMED = "consumed".freeze

    attr_reader :client

    def initialize(client: nil)
      @client = client || Dynamo::Client.new
    end

    def self.hash_value(value) = Digest::SHA256.hexdigest(value.to_s)

    def create
      code = Array.new(CODE_LENGTH) { CODE_ALPHABET.sample(random: SecureRandom) }.join
      poll_id = SecureRandom.urlsafe_base64(24)
      now = Dynamo::Marshal.now_ms
      code_hash = self.class.hash_value(code)
      poll_hash = self.class.hash_value(poll_id)

      # Two items so both lookups are O(1). The app polls every ~2s for up to
      # 90s, so a scan per poll would be the busiest query in the app.
      client.transact_write(puts: [
        { item: {
          "PK" => "HANDOFF##{code_hash}",
          "SK" => "META",
          "entity" => "handoff",
          "code_hash" => code_hash,
          "poll_id_hash" => poll_hash,
          "status" => STATUS_CREATED,
          "created_at" => now,
          "expires_at" => now + TTL_MS,
          "user_id" => nil
        } },
        { item: {
          "PK" => "POLL##{poll_hash}",
          "SK" => "META",
          "entity" => "handoff_poll",
          "code_hash" => code_hash,
          "created_at" => now,
          "expires_at" => now + TTL_MS
        } }
      ])

      { code: code, poll_id: poll_id, expires_at: now + TTL_MS }
    end

    def find_by_code(code)
      return nil if code.blank?

      client.get(pk: "HANDOFF##{self.class.hash_value(code)}", sk: "META", consistent: true)
    end

    def find_by_poll_id(poll_id)
      return nil if poll_id.blank?

      pointer = client.get(pk: "POLL##{self.class.hash_value(poll_id)}", sk: "META", consistent: true)
      return nil if pointer.nil?

      client.get(pk: "HANDOFF##{pointer['code_hash']}", sk: "META", consistent: true)
    end

    def usable?(handoff)
      return false if handoff.nil?
      return false if handoff["status"] == STATUS_CONSUMED
      return false if handoff["expires_at"].to_i <= Dynamo::Marshal.now_ms

      true
    end

    # Safari side: record that this code has been signed in by this user.
    # Conditional so two Safaris racing the same code cannot both win.
    def claim!(code, user_id:)
      handoff = find_by_code(code)
      raise Dynamo::Client::NotFound, "handoff not found" if handoff.nil?

      now = Dynamo::Marshal.now_ms

      client.update(
        pk: handoff["PK"],
        sk: "META",
        updates: { "status" => STATUS_CLAIMED, "user_id" => user_id, "claimed_at" => now },
        # STATUS is a DynamoDB reserved word and must be aliased.
        condition: "#st = :created AND expires_at > :now",
        condition_names: { "#st" => "status" },
        expression_values: {
          ":created" => Dynamo::Marshal.to_attr(STATUS_CREATED),
          ":now" => Dynamo::Marshal.to_attr(now)
        }
      )

      user_id
    end

    # App side: consume a claimed handoff and return the user it belongs to.
    # A second call fails, which is what makes the poll id single-use.
    def redeem!(poll_id)
      handoff = find_by_poll_id(poll_id)
      raise Dynamo::Client::NotFound, "handoff not found" if handoff.nil?
      raise Dynamo::Client::Conflict, "handoff not claimed" unless handoff["status"] == STATUS_CLAIMED
      raise Dynamo::Client::Conflict, "handoff expired" if handoff["expires_at"].to_i <= Dynamo::Marshal.now_ms
      raise Dynamo::Client::Conflict, "handoff has no user" if handoff["user_id"].blank?

      client.update(
        pk: handoff["PK"],
        sk: "META",
        updates: { "status" => STATUS_CONSUMED, "consumed_at" => Dynamo::Marshal.now_ms },
        condition: "#st = :claimed",
        condition_names: { "#st" => "status" },
        expression_values: { ":claimed" => Dynamo::Marshal.to_attr(STATUS_CLAIMED) }
      )

      handoff["user_id"]
    end

    def status_for_poll(poll_id)
      handoff = find_by_poll_id(poll_id)
      return :unknown if handoff.nil?
      return :expired if handoff["expires_at"].to_i <= Dynamo::Marshal.now_ms

      case handoff["status"]
      when STATUS_CREATED then :waiting
      when STATUS_CLAIMED then :claimed
      else :consumed
      end
    end
  end
end
