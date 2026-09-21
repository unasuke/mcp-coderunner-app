module Admin
  class JobsController < BaseController
    before_action :set_job, except: :index

    def index
      @jobs = Job.order(created_at: :desc).includes(:blueprint, :job_result).limit(200)
    end

    def show
      @result = @job.job_result
      @leases = @job.leases.order(:created_at)
      @reruns = @job.reruns.order(:id)
    end

    def approve
      unless @job.approvable?
        return redirect_to admin_job_path(@job),
          alert: "実行環境が #{@job.blueprint.state} です。先に実行環境を承認してください"
      end

      @job.approve!(by: current_user)
      redirect_to admin_job_path(@job), notice: "承認しました"
    end

    # Rejecting does not care what state the Blueprint is in, so jobs that can never
    # be approved do not pile up
    def reject
      return redirect_to(admin_job_path(@job), alert: "却下できる状態ではありません") unless @job.pending_review?

      @job.reject!(by: current_user)
      redirect_to admin_job_path(@job), notice: "却下しました"
    end

    def cancel
      if Jobs::Cancel.call(job: @job)
        redirect_to admin_job_path(@job), notice: "中断を要求しました"
      else
        redirect_to admin_job_path(@job), alert: "中断できる状態ではありません"
      end
    end

    # Running one again is submitting a copy of it, so the answer is a different
    # job -- and the page to be on is the new one
    def rerun
      copy = Jobs::Rerun.call(job: @job, user: current_user)

      unless copy
        return redirect_to admin_job_path(@job),
          alert: "再実行できません。終了済みで、スクリプトが残っていて、実行環境が承認済みのジョブだけです"
      end

      redirect_to admin_job_path(copy), notice: rerun_notice(copy)
    rescue McpToolError => e
      redirect_to admin_job_path(@job), alert: e.message
    end

    private

    def rerun_notice(copy)
      if copy.queued?
        "ジョブ ##{copy.retried_from_id} を再実行します"
      else
        "ジョブ ##{copy.retried_from_id} を複製しました。承認すると実行されます"
      end
    end

    def set_job
      @job = Job.find(params[:id])
    end
  end
end
