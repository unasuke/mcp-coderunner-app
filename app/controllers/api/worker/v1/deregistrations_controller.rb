module Api
  module Worker
    module V1
      # 正常終了時の明示的な離脱。冪等にする。
      # 同じ instance_id で二度来ても、未知の instance_id が来ても 200 を返す。
      class DeregistrationsController < BaseController
        def create
          process = find_process
          return render(json: { released_jobs: [] }) unless process

          released = release_leases(process)
          process.stop!

          render json: { released_jobs: released }
        end

        private

        # result を POST した時点でリースは外れるので、離脱時に残っているリースは
        # 定義上「中断されたジョブ」になる。正常な再起動なので試行回数は見ずに queued へ戻す
        def release_leases(process)
          Lease.active.held_by(process.instance_id).map do |lease|
            Jobs::ReleaseLease.call(lease:, reason: "deregistered", requeue_always: true).id
          end
        end
      end
    end
  end
end
