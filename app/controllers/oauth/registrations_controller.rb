module Oauth
  # RFC 7591 Dynamic Client Registration. Doorkeeper does not ship it, so it is here.
  #
  # What gets registered is a public client -- no client_secret is issued -- and PKCE
  # is required. Nothing rests on whether the client can keep a secret safely. The
  # gate is require_member! in front of /oauth/authorize, not the client's secret.
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

    # Plain HTTP is refused anywhere but loopback
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
