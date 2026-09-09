module Admin
  class WorkersController < BaseController
    def index
      @workers = Worker.order(:created_at)
      @processes = WorkerProcess.where(stopped_at: nil).order(started_at: :desc)
      @server_commit = Rails.configuration.x.mcprb.commit_hash
    end

    # 平文はその場で 1 度だけ表示する。DB に入るのは SHA256 だけなので、閉じたら二度と見られない
    def create
      _worker, token = Worker.issue!(worker_id: params.fetch(:worker_id))
      redirect_to admin_workers_path, notice: "トークンを発行しました（この 1 度だけ表示されます）: #{token}"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_workers_path, alert: e.record.errors.full_messages.join(", ")
    end

    # 行は消さない。worker_processes と過去の leases から参照される
    def revoke
      worker = Worker.find(params[:id])
      worker.revoke!
      redirect_to admin_workers_path, notice: "#{worker.worker_id} を失効させました"
    end
  end
end
