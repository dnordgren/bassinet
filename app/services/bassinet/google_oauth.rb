require "net/http"
require "json"
require "uri"

module Bassinet
  # Google OAuth 2.0 authorization-code flow with PKCE.
  #
  # Design note: after exchanging the code we call the OIDC userinfo endpoint
  # over TLS rather than verifying the id_token's signature ourselves. That is
  # an authenticated server-to-server call to Google, so the response is
  # trustworthy, and it avoids shipping a JWKS cache and a JWT verifier for one
  # provider. If a second provider ever lands, revisit this.
  class GoogleOAuth
    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth".freeze
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo".freeze
    SCOPE = "openid email profile".freeze

    class Error < StandardError; end

    # What we need from a provider to identify someone. `sub` is the identity;
    # everything else is display data we happily overwrite on each login.
    Identity = Struct.new(:sub, :email, :email_verified, :name, :picture, keyword_init: true) do
      def verified? = email_verified == true
    end

    def initialize(client_id: self.class.client_id, client_secret: self.class.client_secret)
      @client_id = client_id
      @client_secret = client_secret
    end

    def self.client_id = ENV["GOOGLE_CLIENT_ID"].presence || credentials_value(:google_client_id)
    def self.client_secret = ENV["GOOGLE_CLIENT_SECRET"].presence || credentials_value(:google_client_secret)

    def self.configured? = client_id.present? && client_secret.present?

    def self.credentials_value(key)
      Rails.application.credentials.dig(key)
    rescue StandardError
      nil
    end

    def self.redirect_uri
      ENV["GOOGLE_REDIRECT_URI"].presence ||
        "#{ENV.fetch('BASSINET_BASE_URL', 'http://localhost:3000')}/auth/google/callback"
    end

    # --- PKCE -------------------------------------------------------------

    def self.generate_verifier
      # 43-128 chars, RFC 7636. 32 random bytes -> 43 base64url chars.
      Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
    end

    def self.challenge_for(verifier)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    # --- step 1: send the user to Google ---------------------------------

    def authorize_url(state:, code_verifier:, login_hint: nil, prompt: nil)
      raise Error, "Google OAuth is not configured" if @client_id.blank?

      params = {
        client_id: @client_id,
        redirect_uri: self.class.redirect_uri,
        response_type: "code",
        scope: SCOPE,
        state: state,
        code_challenge: self.class.challenge_for(code_verifier),
        code_challenge_method: "S256",
        access_type: "online",
        include_granted_scopes: "false"
      }
      params[:login_hint] = login_hint if login_hint.present?
      params[:prompt] = prompt if prompt.present?

      "#{AUTHORIZE_URL}?#{URI.encode_www_form(params)}"
    end

    # --- step 2: exchange the code ---------------------------------------

    def exchange(code:, code_verifier:)
      body = post_form(TOKEN_URL, {
        code: code,
        client_id: @client_id,
        client_secret: @client_secret,
        redirect_uri: self.class.redirect_uri,
        grant_type: "authorization_code",
        code_verifier: code_verifier
      })

      access_token = body["access_token"]
      raise Error, "token exchange returned no access_token" if access_token.blank?

      identity_from_userinfo(access_token)
    end

    def identity_from_userinfo(access_token)
      uri = URI(USERINFO_URL)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"

      response = http_for(uri).request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "userinfo failed (#{response.code})"
      end

      data = JSON.parse(response.body)

      sub = data["sub"]
      email = data["email"]
      raise Error, "userinfo missing sub" if sub.blank?

      Identity.new(
        sub: sub,
        email: email,
        email_verified: data["email_verified"] == true || data["email_verified"] == "true",
        name: data["name"],
        picture: data["picture"]
      )
    end

    private

    def post_form(url, params)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(params)

      response = http_for(uri).request(request)
      body = JSON.parse(response.body) rescue {}

      unless response.is_a?(Net::HTTPSuccess)
        # Never log the body: it can contain the client secret echo or tokens.
        raise Error, "token endpoint returned #{response.code}: #{body['error']}"
      end

      body
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10
      http
    end
  end
end
