module Api
  module Worker
    module V1
      class RegistrationsController < BaseController
        # worker_id はベアラトークンから引く。body の worker_id は照合にだけ使う。
        # クライアントの自己申告で別のワーカーになりすませないようにするため。
        def create
          if params[:worker_id].present? && params[:worker_id] != current_worker.worker_id
            return render json: { error: "worker_id mismatch" }, status: :unauthorized
          end

          reap_previous_processes
          create_process

          render json: {
            server_commit: server_commit,
            protocol_version: Protocol::Constants::PROTOCOL_VERSION,
            outdated: outdated?
          }
        end

        private

        # 同じ worker_id の古い行があれば、その場で死んだものとして片付ける。
        # 後述の掃除を待たない。再起動直後にジョブが宙吊りのまま残るのを避けるため
        def reap_previous_processes
          WorkerProcess.where(worker_id: current_worker.worker_id, stopped_at: nil)
            .where.not(instance_id: params[:instance_id]).find_each do |process|
            Lease.active.held_by(process.instance_id).find_each do |lease|
              Jobs::ReleaseLease.call(lease:, reason: "deregistered", requeue_always: true)
            end
            process.stop!
          end
        end

        def create_process
          WorkerProcess.create!(
            worker_id: current_worker.worker_id,
            instance_id: params.fetch(:instance_id),
            hostname: params[:hostname],
            pid: params[:pid],
            commit_hash: params.fetch(:commit_hash),
            protocol_version: params.fetch(:protocol_version),
            ruby_version: params[:ruby_version],
            docker_version: params[:docker_version],
            capacity: params.fetch(:capacity),
            started_at: Time.current,
            last_heartbeat_at: Time.current
          )
        end
      end
    end
  end
end
