# MCP のクライアントが 401 の WWW-Authenticate から辿ってくるメタデータ。
# Caddy 側でも公開のままにしてある（RFC 9728 / RFC 8414）。
class WellKnownController < ActionController::API
  # RFC 9728
  def protected_resource
    render json: {
      resource: url_for_path("/mcp"),
      authorization_servers: [ issuer ],
      scopes_supported: Doorkeeper.config.default_scopes.to_a,
      bearer_methods_supported: [ "header" ],
      resource_name: McpServerBuilder::NAME
    }
  end

  # RFC 8414
  def authorization_server
    render json: {
      issuer: issuer,
      authorization_endpoint: url_for_path("/oauth/authorize"),
      token_endpoint: url_for_path("/oauth/token"),
      registration_endpoint: url_for_path("/oauth/register"),
      revocation_endpoint: url_for_path("/oauth/revoke"),
      scopes_supported: Doorkeeper.config.default_scopes.to_a,
      response_types_supported: [ "code" ],
      grant_types_supported: %w[authorization_code refresh_token],
      code_challenge_methods_supported: [ "S256" ],
      token_endpoint_auth_methods_supported: [ "none" ]
    }
  end

  private

  def issuer
    Rails.configuration.x.mcp_coderunner_app.base_url.to_s.chomp("/")
  end

  def url_for_path(path)
    URI.join(Rails.configuration.x.mcp_coderunner_app.base_url, path).to_s
  end
end
