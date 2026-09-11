config = Rails.configuration.x.mcp_coderunner_app

Rails.application.config.middleware.use OmniAuth::Builder do
  # Registered without credentials, it sends people to GitHub with an empty
  # client_id and looks like GitHub sign-in is broken. Say what is missing up front
  if config.github_client_id.present? && config.github_client_secret.present?
    # read:user and nothing else. No repo scope is needed
    provider :github, config.github_client_id, config.github_client_secret, scope: "read:user"
  end

  # The development door that skips GitHub. It is registered only where the
  # configuration says so outright. From the issued session onward it walks exactly
  # the same path as the GitHub route, which is enough to exercise the
  # authorization flow.
  if config.allow_developer_login
    provider :developer, fields: [ :nickname ], uid_field: :nickname
  end
end

# Sign-in cannot be started with a GET (paired with omniauth-rails_csrf_protection)
OmniAuth.config.allowed_request_methods = [ :post ]
