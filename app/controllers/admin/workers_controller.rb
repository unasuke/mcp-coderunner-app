module Admin
  class WorkersController < BaseController
    def index
      @workers = Worker.order(:created_at)
      @processes = WorkerProcess.where(stopped_at: nil).order(started_at: :desc)
      @server_commit = Rails.configuration.x.mcp_coderunner_app.commit_hash
    end

    # The plaintext is shown once, right there. Only the SHA256 is stored, so once
    # the page is closed it is gone for good
    def create
      worker, token = Worker.issue!(worker_id: params.fetch(:worker_id))
      # The plaintext rides in the flash and nowhere else. What is stored is the hash
      flash[:issued_token] = token
      redirect_to admin_workers_path, notice: "#{worker.worker_id} のトークンを発行しました"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_workers_path, alert: e.record.errors.full_messages.join(", ")
    end

    # The row stays. worker_processes and past leases refer to it
    def revoke
      worker = Worker.find(params[:id])
      worker.revoke!
      redirect_to admin_workers_path, notice: "#{worker.worker_id} を失効させました"
    end
  end
end
