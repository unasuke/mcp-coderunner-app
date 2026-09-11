require "test_helper"

# /oauth/authorize is the one real gate, so this walks the whole thing for real.
# An authorization code is only issued to a session holding member or above.
class OauthTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "http://localhost:6274/oauth/callback".freeze

  setup do
    OmniAuth.config.test_mode = true
    @application = Doorkeeper::Application.create!(
      name: "inspector", redirect_uri: REDIRECT_URI, confidential: false, scopes: ""
    )
    @verifier = SecureRandom.urlsafe_base64(64)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  def sign_in(role:, login: "unasuke", uid: "1")
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: uid, info: { nickname: login, name: login, image: nil }
    )
    post "/auth/github"
    follow_redirect!
    User.find_by(github_uid: uid).tap { |user| user.update!(role:) }
  end

  def challenge
    Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def authorize_params
    {
      client_id: @application.uid,
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }
  end

  test "an anonymous visitor is sent to the GitHub login" do
    get "/oauth/authorize", params: authorize_params

    assert_redirected_to login_path
  end

  # A pending user can do nothing at all -- and is not dropped into a sign-in loop either
  test "a pending user is stopped at the waiting page" do
    sign_in(role: :pending)

    get "/oauth/authorize", params: authorize_params

    assert_redirected_to pending_path
  end

  test "a member reaches the consent screen" do
    sign_in(role: :member)

    get "/oauth/authorize", params: authorize_params

    assert_response :success
  end

  # With this passing, the path that runs once this is public holds together
  test "the full authorization code flow with PKCE" do
    user = sign_in(role: :member)

    post "/oauth/authorize", params: authorize_params
    code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")

    post "/oauth/token", params: {
      grant_type: "authorization_code", code:, redirect_uri: REDIRECT_URI,
      client_id: @application.uid, code_verifier: @verifier
    }

    assert_response :success
    body = response.parsed_body
    assert_equal "Bearer", body["token_type"]
    assert_equal 900, body["expires_in"]
    assert body["refresh_token"]

    token = Doorkeeper::AccessToken.by_token(body["access_token"])
    assert_equal user.id, token.resource_owner_id

    # The token that came back actually reaches a tool
    post "/mcp", headers: { "Authorization" => "Bearer #{body['access_token']}" }, as: :json,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :success
    assert_equal 4, response.parsed_body.dig("result", "tools").size
  end

  # There was a hole where a missing column meant PKCE was silently ignored.
  # A happy path alone lets that come back
  test "an authorization without a code_challenge is refused" do
    sign_in(role: :member)

    get "/oauth/authorize", params: authorize_params.except(:code_challenge, :code_challenge_method)

    assert_response :bad_request
    assert_match(/Code challenge is required/, response.body)
  end

  # plain verifies nothing
  test "the plain challenge method is refused" do
    sign_in(role: :member)

    get "/oauth/authorize", params: authorize_params.merge(
      code_challenge: @verifier, code_challenge_method: "plain"
    )

    assert_response :bad_request
  end

  # PKCE is required, so a verifier that does not match cannot be exchanged
  test "a wrong code_verifier is refused" do
    sign_in(role: :member)

    post "/oauth/authorize", params: authorize_params
    code = Rack::Utils.parse_query(URI.parse(response.location).query).fetch("code")

    post "/oauth/token", params: {
      grant_type: "authorization_code", code:, redirect_uri: REDIRECT_URI,
      client_id: @application.uid, code_verifier: SecureRandom.urlsafe_base64(64)
    }

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end
end
