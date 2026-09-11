config = Rails.configuration.x.mcp_coderunner_app

Rails.application.config.middleware.use OmniAuth::Builder do
  # 資格情報が無いまま登録すると、client_id が空の URL で GitHub に飛ばされ、
  # 「GitHub ログインが壊れている」ように見える。設定漏れは手前で言う
  if config.github_client_id.present? && config.github_client_secret.present?
    # read:user のみ要求する。repo スコープは要らない
    provider :github, config.github_client_id, config.github_client_secret, scope: "read:user"
  end

  # GitHub を経由しない開発用の口。設定で明示的に許可された環境にしか生えない。
  # セッションの発行から先は GitHub 経由とまったく同じ経路を通るので、
  # 認可フローの検証はこれで足りる。
  if config.allow_developer_login
    provider :developer, fields: [ :nickname ], uid_field: :nickname
  end
end

# GET でのログイン開始を許さない（omniauth-rails_csrf_protection と組で使う）
OmniAuth.config.allowed_request_methods = [ :post ]
