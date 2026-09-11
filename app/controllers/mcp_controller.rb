# The MCP resource server itself. It verifies the token through Doorkeeper, puts
# the resource owner on Current, and hands off to the SDK's handler -- nothing more,
# which is what keeps authentication out of sight of the tool implementations.
class McpController < ActionController::API
  before_action :doorkeeper_authorize!
  before_action :set_current
  before_action :require_member!

  def create
    body = McpServerBuilder.build.handle_json(request.raw_post)

    if body
      render plain: body, content_type: "application/json"
    else
      # A notification (a request without an id) has nothing to answer with
      head :accepted
    end
  end

  # No SSE stream is offered, and the specification calls for a 405 in that case.
  # Nothing here holds a session either (it is stateless), so there is no DELETE to end one.
  def unsupported
    headers["Allow"] = "POST"
    render json: { error: "method_not_allowed" }, status: :method_not_allowed
  end

  private

  # A valid token is not enough for a user who has been demoted or deleted.
  # What someone is allowed to do is not left to a token's 15-minute lifetime
  def require_member!
    return if Current.user&.can_use_mcp?

    render json: {
      error: "forbidden",
      message: "このアカウントはこのサーバーを使えません。管理者の承認が要ります"
    }, status: :forbidden
  end

  def set_current
    Current.user = doorkeeper_token&.resource_owner_id&.then { |id| User.find_by(id:) }
    Current.oauth_application = doorkeeper_token&.application
  end

  # RFC 9728. Points from the 401 at the resource metadata
  def doorkeeper_unauthorized_render_options(error: nil)
    metadata = URI.join(Rails.configuration.x.mcp_coderunner_app.base_url, "/.well-known/oauth-protected-resource").to_s
    headers["WWW-Authenticate"] = %(Bearer realm="mcp-coderunner-app", resource_metadata="#{metadata}")

    { json: { error: "unauthorized", message: error&.description } }
  end

  # Insufficient scope. This is an API, so it answers in JSON rather than an HTML error page
  def doorkeeper_forbidden_render_options(error: nil)
    { json: { error: "forbidden", message: error&.description } }
  end
end
