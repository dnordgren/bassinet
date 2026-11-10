module Bassinet
  # Users are global, not household-scoped: one person can belong to several
  # households (grandparent, two families, whatever). So this repo takes no
  # household and is deliberately the one exception to the Repo base class.
  class UserRepo
    class NotFound < StandardError; end

    attr_reader :client

    def initialize(client: nil)
      @client = client || Dynamo::Client.new
    end

    def find(user_id)
      item = client.get(pk: Dynamo::Keys.user_pk(user_id), sk: Dynamo::Keys.user_profile_sk)
      item && hydrate(item)
    end

    def find_by_email(email)
      index = client.get(pk: Dynamo::Keys.email_pk(email), sk: Dynamo::Keys.email_index_sk)
      return nil if index.nil?

      find(index["user_sub"])
    end

    # Creates the user, the email index row, and the initial household in one
    # transaction — a partial failure here would strand a member with no
    # household, which the rest of the app cannot recover from.
    def provision!(user_id:, email:, name: nil, avatar_url: nil, household_name: nil)
      now = Dynamo::Marshal.now_ms
      household_id = "hh_#{SecureRandom.uuid.delete('-')[0, 20]}"

      user_item = {
        "PK" => Dynamo::Keys.user_pk(user_id),
        "SK" => Dynamo::Keys.user_profile_sk,
        "entity" => "user",
        "user_id" => user_id,
        "email" => email.to_s.downcase.strip,
        "name" => name,
        "avatar_url" => avatar_url,
        "provider" => "google",
        "created_at" => now,
        "updated_at" => now
      }

      email_item = {
        "PK" => Dynamo::Keys.email_pk(email),
        "SK" => Dynamo::Keys.email_index_sk,
        "entity" => "email_index",
        "user_sub" => user_id,
        "created_at" => now
      }

      household_item = {
        "PK" => Dynamo::Keys.household_pk(household_id),
        "SK" => Dynamo::Keys.household_meta_sk,
        "entity" => "household",
        "household_id" => household_id,
        "name" => household_name.presence || "#{name.presence || 'Our'} household",
        "owner_id" => user_id,
        "created_at" => now,
        "updated_at" => now,
        "deleted_at" => nil
      }

      member_item = {
        "PK" => Dynamo::Keys.household_pk(household_id),
        "SK" => Dynamo::Keys.member_sk(user_id),
        "entity" => "member",
        "household_id" => household_id,
        "user_id" => user_id,
        "role" => "owner",
        "display_name" => name,
        "email" => email.to_s.downcase.strip,
        "avatar_url" => avatar_url,
        "joined_at" => now,
        "updated_at" => now,
        "deleted_at" => nil,
        "GSI2PK" => "USER##{user_id}",
        "GSI2SK" => Dynamo::Keys.household_pk(household_id)
      }

      client.transact_write(puts: [
        { item: user_item },
        { item: email_item },
        { item: household_item },
        { item: member_item }
      ])

      { user: hydrate(user_item), household_id: household_id }
    rescue Dynamo::Client::Conflict => e
      raise e
    end

    # Refreshes display fields from a provider response without touching identity.
    def refresh_profile(user_id, email: nil, name: nil, avatar_url: nil)
      current = find(user_id)
      return nil if current.nil?

      updates = {}
      updates["email"] = email.to_s.downcase.strip if email.present? && email.downcase.strip != current.email
      updates["name"] = name if name.present? && name != current.name
      updates["avatar_url"] = avatar_url if avatar_url.present? && avatar_url != current.avatar_url
      return current if updates.empty?

      updates["updated_at"] = Dynamo::Marshal.now_ms
      hydrate(client.update(
        pk: Dynamo::Keys.user_pk(user_id),
        sk: Dynamo::Keys.user_profile_sk,
        updates: updates
      ))
    end

    def households_for(user_id)
      client.query_items(
        index_name: "GSI2",
        key_condition_expression: "GSI2PK = :pk",
        expression_attribute_values: {
          ":pk" => Dynamo::Marshal.to_attr("USER##{user_id}")
        }
      ).reject { |i| i["deleted_at"] }
    end

    private

    def hydrate(item)
      User.new(
        user_id: item["user_id"],
        email: item["email"],
        name: item["name"],
        avatar_url: item["avatar_url"],
        provider: item["provider"],
        created_at: item["created_at"],
        updated_at: item["updated_at"]
      )
    end
  end
end
