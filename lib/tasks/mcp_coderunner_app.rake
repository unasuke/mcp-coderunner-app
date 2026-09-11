namespace :mcp_coderunner_app do
  namespace :worker do
    desc "Put a development worker token in tmp/worker_token (idempotent)"
    task dev_token: :environment do
      # A development-only door. It opens nowhere else
      abort "development only (this is #{Rails.env})" unless Rails.env.development?

      worker_id = YAML.safe_load_file(Rails.root.join("config/worker.dev.yml")).fetch("worker_id")
      path = Rails.root.join("tmp/worker_token")

      if path.exist? && Worker.active.exists?(worker_id:)
        puts "already there: #{path}"
        next
      end

      # The plaintext is never stored, so an old row cannot be matched against. Make a new one
      Worker.where(worker_id:).destroy_all
      _worker, token = Worker.issue!(worker_id:)

      path.dirname.mkpath
      path.write(token)
      path.chmod(0o600)
      puts "issued: #{path}"
    end
  end
end
