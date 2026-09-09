module Api
  module Worker
    module V1
      class JobsController < BaseController
        before_action :set_job
        before_action :authenticate_lease!

        # 30 秒ごと。build 中も打つ。受けるたびに lease_expires_at を延ばす。
        # 「生きている限り延びる」形なら、ビルドが何分かかるかを事前に見積もる必要がない
        def heartbeat
          @lease.extend!
          @job.running! if @job.leased?

          render json: {
            lease_expires_at: @lease.expires_at.utc.iso8601,
            cancel: @job.cancel_requested?
          }
        end

        # 結果はジョブに 1 行だけ。lease が失効していたら 409 で拒否する
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
