module Api
  module Worker
    module V1
      class LeasesController < BaseController
        # Long polling. Waits up to LEASE_WAIT seconds, and answers 204 with no job.
        # The delay between enqueue and start is felt directly in the chat.
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

        # Nothing here rides on a notification mechanism. SQLite has no LISTEN/NOTIFY,
        # and routing it through Solid Queue ends in polling somewhere anyway.
        #
        # One beat! per request is enough: holding the long poll open is itself proof
        # of life, and the window is 25 seconds against a two-minute expiry.
        def wait_for_job(process)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Protocol::Constants::LEASE_WAIT
          process.beat!

          loop do
            claimed = Jobs::Claim.call(instance_id: process.instance_id)
            return claimed if claimed
            return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep Protocol::Constants::LEASE_POLL_INTERVAL
          end
        end

        # limits is what was asked for, and the worker reads it as a ceiling and nothing else
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
