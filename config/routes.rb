Rails.application.routes.draw do
  use_doorkeeper

  # OAuth のメタデータと動的クライアント登録（Doorkeeper が持っていない分）
  # クライアントによってはリソースのパスを後ろに付けて引きに来る（RFC 9728 の
  # /.well-known/oauth-protected-resource/mcp 形式）。どちらでも同じものを返す
  get ".well-known/oauth-protected-resource(/*resource)" => "well_known#protected_resource"
  get ".well-known/oauth-authorization-server(/*resource)" => "well_known#authorization_server"
  post "oauth/register" => "oauth/registrations#create"

  # GitHub ログイン
  get "login" => "sessions#new", as: :login
  post "auth/github", as: :github_auth
  get "auth/github/callback" => "sessions#create"
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

    resources :workers, only: [ :index, :create ] do
      member { post :revoke }
    end
  end

  # MCP のリソースサーバー本体。Anthropic のレンジからのみ到達できる（Caddy 側で絞る）
  post "mcp" => "mcp#create", as: :mcp
  match "mcp" => "mcp#unsupported", via: [ :get, :delete ]

  # ワーカーから。すべてワーカー発の HTTPS
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

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "admin/jobs#index"
end
