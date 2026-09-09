# リクエストごとの主体。McpController と ApplicationController が載せる。
# ツールの実装から認証の存在が見えないようにしておくため。
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :oauth_application, :session
end
