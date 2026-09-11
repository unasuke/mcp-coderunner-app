# Who the request is acting as. McpController and ApplicationController set it,
# which is what keeps authentication out of sight of the tool implementations.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :oauth_application, :session
end
