module Oauth
  # RFC 7591 Dynamic Client Registration。Doorkeeper が持っていないので自前で足す。
  #
  # 発行するのは public クライアント（client_secret を出さない）で、PKCE を必須にする。
  # Claude 側が secret を安全に保持できるかどうかに依存させない。認可の関門は
  # /oauth/authorize の require_member! であって、client の秘密ではない。
  class RegistrationsController < ActionController::API
    def create
      redirect_uris = Array(params[:redirect_uris]).map(&:to_s).reject(&:blank?)
      return render(json: invalid("redirect_uris is required"), status: :bad_request) if redirect_uris.empty?

      invalid_uri = redirect_uris.find { |uri| !valid_redirect_uri?(uri) }
      return render(json: invalid("invalid redirect_uri: #{invalid_uri}"), status: :bad_request) if invalid_uri

      application = Doorkeeper::Application.create!(
        name: params[:client_name].presence || "MCP client",
        redirect_uri: redirect_uris.join("\n"),
        scopes: "",
        confidential: false
      )

      render json: registration_for(application), status: :created
    end

    private

    def registration_for(application)
      {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        client_name: application.name,
        redirect_uris: application.redirect_uri.split("\n"),
        grant_types: %w[authorization_code refresh_token],
        response_types: %w[code],
        token_endpoint_auth_method: "none",
        scope: Doorkeeper.config.default_scopes.to_s
      }
    end

    # ループバック以外の平文 HTTP は受け付けない
    def valid_redirect_uri?(uri)
      parsed = URI.parse(uri)
      return true if parsed.scheme == "https"

      parsed.scheme == "http" && [ "localhost", "127.0.0.1", "::1" ].include?(parsed.host)
    rescue URI::InvalidURIError
      false
    end

    def invalid(description)
      { error: "invalid_redirect_uri", error_description: description }
    end
  end
end
