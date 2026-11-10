module Bassinet
  # A person. Identity is the Google `sub` — stable forever, never changes.
  # Email is a display field plus a lookup index, not an identity.
  class User
    attr_reader :user_id, :email, :name, :avatar_url, :provider, :created_at, :updated_at

    def initialize(user_id:, email:, name: nil, avatar_url: nil,
                   provider: "google", created_at: nil, updated_at: nil)
      @user_id = user_id
      @email = email
      @name = name
      @avatar_url = avatar_url
      @provider = provider
      @created_at = created_at
      @updated_at = updated_at
    end

    def display_name
      name.presence || email.to_s.split("@").first
    end

    def initials
      display_name.to_s.split(/[\s._-]+/).reject(&:empty?).first(2).map { |p| p[0].upcase }.join
    end

    def as_json
      {
        "user_id" => user_id,
        "email" => email,
        "name" => name,
        "avatar_url" => avatar_url,
        "display_name" => display_name
      }
    end
  end
end
