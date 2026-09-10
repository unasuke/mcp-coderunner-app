namespace :mcprb do
  namespace :worker do
    desc "development 用のワーカートークンを tmp/worker_token に用意する（冪等）"
    task dev_token: :environment do
      # 開発用の口。development でしか通さない
      abort "development でのみ使えます（今は #{Rails.env}）" unless Rails.env.development?

      worker_id = YAML.safe_load_file(Rails.root.join("config/worker.dev.yml")).fetch("worker_id")
      path = Rails.root.join("tmp/worker_token")

      if path.exist? && Worker.active.exists?(worker_id:)
        puts "既にあります: #{path}"
        next
      end

      # 平文は保存されないので、古い行が残っていても照合できない。作り直す
      Worker.where(worker_id:).destroy_all
      _worker, token = Worker.issue!(worker_id:)

      path.dirname.mkpath
      path.write(token)
      path.chmod(0o600)
      puts "発行しました: #{path}"
    end
  end
end
