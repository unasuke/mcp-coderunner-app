module Api
  module Worker
    module V1
      class JobsController < BaseController
        before_action :set_job
        before_action :authenticate_lease!

        # Every 30 seconds, during a build as well. Each one pushes lease_expires_at
        # further out. With the lease living as long as the worker does, nobody has to
        # guess up front how many minutes a build will take
        def heartbeat
          @lease.extend!
          @job.running! if @job.leased?

          render json: {
            lease_expires_at: @lease.expires_at.utc.iso8601,
            cancel: @job.cancel_requested?
          }
        end

        # One result row per job, and an expired lease is turned away with a 409
        def result
          Jobs::RecordResult.call(job: @job, lease_token: params[:lease_token], attributes: result_attributes)

          render json: { ok: true }
        rescue Jobs::RecordResult::Conflict => e
          render json: { error: "lease_expired", message: e.message }, status: :conflict
        end

        private

        def set_job
          @job = Job.find_by(id: params[:id])
          render(json: { error: "job_not_found" }, status: :not_found) unless @job
        end

        def authenticate_lease!
          @lease = @job.active_lease
          return if @lease&.authenticate(params[:lease_token])

          render json: { error: "lease_expired" }, status: :conflict
        end

        def result_attributes
          params.permit(:termination_reason, :exit_code, :stdout, :stderr, :truncated,
            :duration_ms, :cpu_time_ms, :max_rss_bytes, :image_digest,
            applied_limits: {}).to_h.symbolize_keys
        end
      end
    end
  end
end
