module Api
  module Worker
    module V1
      class HeartbeatsController < BaseController
        # Every 30 seconds, job or no job.
        # The worker does not get to declare it is busy; the server counts unreleased leases
        def create
          process = find_process
          return render(json: { error: "unknown instance" }, status: :not_found) unless process

          process.beat!

          render json: {
            server_commit: server_commit,
            outdated: outdated?,
            # On a protocol mismatch, tell it to stop taking new leases
            drain: !protocol_matches?
          }
        end
      end
    end
  end
end
