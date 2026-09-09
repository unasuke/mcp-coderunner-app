module Api
  module Worker
    module V1
      class LeasesController < BaseController
        # ロングポーリング。最大 LEASE_WAIT 秒待って、ジョブが無ければ 204。
        # enqueue から実行開始までの遅延はそのままチャットの体感になる。
        def create
          unless protocol_matches?
            return render json: {
              error: "protocol_version mismatch",
              expected: Protocol::Constants::PROTOCOL_VERSION
            }, status: :conflict
          end

          process = find_process
          return render(json: { error: "unknown instance" }, status: :not_found) unless process

          claimed = wait_for_job(process)
          return head(:no_content) unless claimed

          render json: payload_for(claimed)
        end

        private

        # 通知の仕組みには乗せない。SQLite に LISTEN/NOTIFY 相当が無く、
        # Solid Queue の経路に載せても結局どこかでポーリングになる
        def wait_for_job(process)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Protocol::Constants::LEASE_WAIT

          loop do
            process.beat!
            claimed = Jobs::Claim.call(instance_id: process.instance_id)
            return claimed if claimed
            return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 1
          end
        end

        # limits は要求値であり、ワーカーはこれを上限としてのみ解釈する
        def payload_for(claimed)
          job = claimed.job

          {
            job_id: job.id,
            lease_id: claimed.lease.id,
            lease_token: claimed.token,
            lease_expires_at: claimed.lease.expires_at.utc.iso8601,
            blueprint: job.blueprint.to_lease_payload,
            script: job.script,
            profile: job.profile,
            entrypoint: job.entrypoint_or_default,
            limits: job.limits
          }
        end
      end
    end
  end
end
