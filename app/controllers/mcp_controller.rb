# MCP のリソースサーバー本体。Doorkeeper でトークンを検証し、resource owner を
# Current に載せてから SDK のハンドラに委譲するだけにする。
# ツールの実装から認証の存在が見えないようにしておくため。
class McpController < ActionController::API
  before_action :doorkeeper_authorize!
  before_action :set_current
  before_action :require_member!

  def create
    body = McpServerBuilder.build.handle_json(request.raw_post)

    if body
      render plain: body, content_type: "application/json"
    else
      # 通知（id の無いリクエスト）には返すものが無い
      head :accepted
    end
  end

  # SSE のストリームは提供しない。仕様上、その場合は 405 を返す必要がある。
  # ここでのセッションは持たない（stateless）ので、DELETE での終了も無い。
  def unsupported
    headers["Allow"] = "POST"
    render json: { error: "method_not_allowed" }, status: :method_not_allowed
  end

  private

  # トークンが有効でも、降格されたユーザーや消えたユーザーは通さない。
  # 権限の判定をトークンの寿命（15 分）に任せない
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

  # RFC 9728。401 からリソースメタデータを指す
  def doorkeeper_unauthorized_render_options(error: nil)
    metadata = URI.join(Rails.configuration.x.mcp_coderunner_app.base_url, "/.well-known/oauth-protected-resource").to_s
    headers["WWW-Authenticate"] = %(Bearer realm="mcp-coderunner-app", resource_metadata="#{metadata}")

    { json: { error: "unauthorized", message: error&.description } }
  end

  # スコープ不足。API なので HTML のエラーページではなく JSON で返す
  def doorkeeper_forbidden_render_options(error: nil)
    { json: { error: "forbidden", message: error&.description } }
  end
end
