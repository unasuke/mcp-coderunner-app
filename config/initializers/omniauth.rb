# read:user のみ要求する。repo スコープは要らない。
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    Rails.configuration.x.mcp_sandbox_app.github_client_id,
    Rails.configuration.x.mcp_sandbox_app.github_client_secret,
    scope: "read:user"

  # GitHub を経由しない開発用の口。設定で明示的に許可された環境にしか生えない。
  # セッションの発行から先は GitHub 経由とまったく同じ経路を通るので、
  # 認可フローの検証はこれで足りる。
  if Rails.configuration.x.mcp_sandbox_app.allow_developer_login
    provider :developer, fields: [ :nickname ], uid_field: :nickname
  end
end

# GET でのログイン開始を許さない（omniauth-rails_csrf_protection と組で使う）
OmniAuth.config.allowed_request_methods = [ :post ]
