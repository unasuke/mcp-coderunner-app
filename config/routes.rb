Rails.application.routes.draw do
  use_doorkeeper

  # The OAuth metadata, and the dynamic client registration Doorkeeper does not ship.
  # Some clients ask with the resource path appended (the RFC 9728
  # /.well-known/oauth-protected-resource/mcp form). Both shapes answer the same
  get ".well-known/oauth-protected-resource(/*resource)" => "well_known#protected_resource"
  get ".well-known/oauth-authorization-server(/*resource)" => "well_known#authorization_server"
  post "oauth/register" => "oauth/registrations#create"

  # GitHub sign-in
  get "login" => "sessions#new", as: :login
  # Normally OmniAuth's middleware takes this. A request reaching the controller
  # means the GitHub credentials were never configured
  post "auth/github" => "sessions#github", as: :github_auth
  get "auth/github/callback" => "sessions#create"
  # The developer sign-in's callback, POSTed from a form OmniAuth generated.
  # With the setting off it answers 404, and the strategy is not registered either,
  # so it is shut twice over
  match "auth/developer/callback" => "sessions#developer", via: [ :get, :post ]
  get "auth/failure" => "sessions#failure"
  delete "logout" => "sessions#destroy", as: :logout
  get "pending" => "sessions#pending", as: :pending

  namespace :admin do
    resources :blueprints, only: [ :index, :show ] do
      member do
        post :approve
        post :reject
        post :revoke
      end
    end

    resources :jobs, only: [ :index, :show ] do
      member do
        post :approve
        post :reject
        post :cancel
      end
    end

    resources :users, only: [ :index, :update ]

    # One browser's agreement to be notified, not a person's
    resource :push_subscription, only: [ :create, :destroy ]

    resources :workers, only: [ :index, :create ] do
      member { post :revoke }
    end
  end

  # The MCP resource server itself. Reachable only from Anthropic's ranges, which
  # Caddy narrows
  post "mcp" => "mcp#create", as: :mcp
  match "mcp" => "mcp#unsupported", via: [ :get, :delete ]

  # From the worker. Every one of these is HTTPS the worker started
  namespace :api do
    namespace :worker do
      namespace :v1 do
        post "register" => "registrations#create"
        post "heartbeat" => "heartbeats#create"
        post "deregister" => "deregistrations#create"
        post "lease" => "leases#create"
        post "jobs/:id/heartbeat" => "jobs#heartbeat", as: :job_heartbeat
        post "jobs/:id/result" => "jobs#result", as: :job_result
      end
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The service worker is what receives a push while nothing is open, so it has to
  # be served from the root to have the whole site in its scope. Both are public:
  # the manifest names the app and the worker holds no secret
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "admin/jobs#index"
end
