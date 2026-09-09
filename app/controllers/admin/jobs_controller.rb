module Admin
  class JobsController < BaseController
    before_action :set_job, except: :index

    def index
      @jobs = Job.order(created_at: :desc).includes(:blueprint, :job_result).limit(200)
    end

    def show
      @result = @job.job_result
      @leases = @job.leases.order(:created_at)
    end

    def approve
      return redirect_to(admin_job_path(@job), alert: "承認できる状態ではありません") unless @job.approvable?

      @job.approve!(by: current_user)
      redirect_to admin_job_path(@job), notice: "承認しました"
    end

    def reject
      return redirect_to(admin_job_path(@job), alert: "却下できる状態ではありません") unless @job.approvable?

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

    private

    def set_job
      @job = Job.find(params[:id])
    end
  end
end
