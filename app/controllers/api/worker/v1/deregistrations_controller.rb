module Api
  module Worker
    module V1
      # An orderly departure, stated outright, and idempotent.
      # The same instance_id twice, or one nobody has heard of, both answer 200.
      class DeregistrationsController < BaseController
        def create
          process = find_process
          return render(json: { released_jobs: [] }) unless process

          released = release_leases(process)
          process.stop!

          render json: { released_jobs: released }
        end

        private

        # A lease comes off the moment its result is POSTed, so a lease still held at
        # departure is by definition a job that got interrupted. This is an orderly
        # restart, so it goes back to queued without the attempt count being consulted
        def release_leases(process)
          Lease.active.held_by(process.instance_id).map do |lease|
            Jobs::ReleaseLease.call(lease:, reason: "deregistered", requeue_always: true).id
          end
        end
      end
    end
  end
end
