module Api
  module Worker
    module V1
      class RegistrationsController < BaseController
        # The worker_id comes from the bearer token; the one in the body is only
        # compared against it, so that nothing a client says about itself can pass
        # it off as a different worker.
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

        # An older row under the same worker_id is put to rest here and now, rather
        # than waiting for the sweep, so that a job is not left hanging right after
        # a restart.
        #
        # This is where an unclean exit lands, so it counts as expired. A clean stop
        # would have gone through /deregister first, and that one requeues without
        # consulting the attempt count. Using requeue_always here would let a
        # Restart=always crash loop pick the same job up forever, since /deregister
        # is never called and the count never grows
        def reap_previous_processes
          WorkerProcess.where(worker_id: current_worker.worker_id, stopped_at: nil)
            .where.not(instance_id: params[:instance_id]).find_each do |process|
            Lease.active.held_by(process.instance_id).find_each do |lease|
              Jobs::ReleaseLease.call(lease:, reason: "expired")
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
