module Bassinet
  # Household membership, invites, and role checks. Scoped to one household.
  class HouseholdRepo < Repo
    ROLES = %w[owner caregiver].freeze
    MAX_MEMBERS = 4
    INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000
    INVITE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ".chars.freeze # Crockford-ish, no I/L/O/U
    INVITE_LENGTH = 8

    def find
      client.get(pk: Dynamo::Keys.household_pk(household_id),
                 sk: Dynamo::Keys.household_meta_sk)
    end

    def members
      client.query_items(
        key_condition_expression: "PK = :pk AND begins_with(SK, :member)",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr(Dynamo::Keys.household_pk(household_id)),
          ":member" => Dynamo::Marshal.to_attr("MEMBER#")
        }
      ).reject { |i| i["deleted_at"] }
       .map { |i| i.slice("user_id", "role", "display_name", "email", "avatar_url", "joined_at") }
    end

    def member?(user_id)
      members.any? { |m| m["user_id"] == user_id }
    end

    def role_for(user_id)
      members.find { |m| m["user_id"] == user_id }&.fetch("role", nil)
    end

    def owner?(user_id) = role_for(user_id) == "owner"

    def add_member!(user_id:, role:, display_name: nil, email: nil, avatar_url: nil)
      raise ArgumentError, "invalid role #{role}" unless ROLES.include?(role.to_s)
      raise Dynamo::Client::ValidationFailed, "household is full" if members.size >= MAX_MEMBERS

      now = Dynamo::Marshal.now_ms
      item = {
        "PK" => Dynamo::Keys.household_pk(household_id),
        "SK" => Dynamo::Keys.member_sk(user_id),
        "entity" => "member",
        "household_id" => household_id,
        "user_id" => user_id,
        "role" => role.to_s,
        "display_name" => display_name,
        "email" => email,
        "avatar_url" => avatar_url,
        "joined_at" => now,
        "updated_at" => now,
        "deleted_at" => nil,
        "GSI2PK" => "USER##{user_id}",
        "GSI2SK" => Dynamo::Keys.household_pk(household_id)
      }

      client.put(item, condition: "attribute_not_exists(PK)")
      item
    end

    def remove_member!(user_id)
      raise Dynamo::Client::ValidationFailed, "cannot remove the owner" if owner?(user_id)

      client.update(
        pk: Dynamo::Keys.household_pk(household_id),
        sk: Dynamo::Keys.member_sk(user_id),
        updates: { "deleted_at" => Dynamo::Marshal.now_ms, "updated_at" => Dynamo::Marshal.now_ms }
      )
    end

    # --- invites ----------------------------------------------------------

    # Returns the plaintext token once. Only the hash is ever stored, so this
    # value cannot be recovered later — it goes in the link and nowhere else.
    def create_invite!(created_by:, role: "caregiver")
      raise Dynamo::Client::ValidationFailed, "household is full" if members.size >= MAX_MEMBERS

      token = Array.new(INVITE_LENGTH) { INVITE_ALPHABET.sample(random: SecureRandom) }.join
      token_hash = self.class.hash_token(token)
      now = Dynamo::Marshal.now_ms

      client.put({
        "PK" => Dynamo::Keys.household_pk(household_id),
        "SK" => Dynamo::Keys.invite_sk(token_hash),
        "entity" => "invite",
        "household_id" => household_id,
        "role" => role.to_s,
        "created_by" => created_by,
        "created_at" => now,
        "expires_at" => now + INVITE_TTL_MS,
        "claimed_by" => nil,
        "claimed_at" => nil
      })

      { token: token, expires_at: now + INVITE_TTL_MS, role: role.to_s }
    end

    def find_invite(token)
      client.get(pk: Dynamo::Keys.household_pk(household_id),
                 sk: Dynamo::Keys.invite_sk(self.class.hash_token(token)))
    end

    # Conditional write so two people racing the same link cannot both join.
    def claim_invite!(token, user_id:)
      token_hash = self.class.hash_token(token)
      now = Dynamo::Marshal.now_ms

      client.update(
        pk: Dynamo::Keys.household_pk(household_id),
        sk: Dynamo::Keys.invite_sk(token_hash),
        updates: { "claimed_by" => user_id, "claimed_at" => now },
        condition: "attribute_exists(SK) AND attribute_not_exists(claimed_by) AND expires_at > :now",
        expression_values: { ":now" => Dynamo::Marshal.to_attr(now) }
      )

      find_invite(token)
    end

    def self.hash_token(token)
      Digest::SHA256.hexdigest(token.to_s.strip.upcase)
    end
  end
end
