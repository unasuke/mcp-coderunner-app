Rails.application.routes.draw do
  use_doorkeeper

  # MCP のリソースサーバー本体。Anthropic のレンジからのみ到達できる（Caddy 側で絞る）
  post "mcp" => "mcp#create", as: :mcp

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

  # Defines the root path route ("/")
  # root "posts#index"
end
