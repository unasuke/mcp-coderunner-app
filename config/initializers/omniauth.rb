# read:user のみ要求する。repo スコープは要らない。
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    Rails.configuration.x.mcprb.github_client_id,
    Rails.configuration.x.mcprb.github_client_secret,
    scope: "read:user"
end

# GET でのログイン開始を許さない（omniauth-rails_csrf_protection と組で使う）
OmniAuth.config.allowed_request_methods = [ :post ]
