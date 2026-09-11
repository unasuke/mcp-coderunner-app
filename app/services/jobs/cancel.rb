module Jobs
  # Cancel is available in every state from queued onward (pending_review ends by
  # being rejected instead).
  #
  # From leased on it cannot stop anything immediately, because the heartbeat is
  # the only channel that reaches the worker. As long as nothing listens on the
  # home side, that does not change.
  class Cancel
    def self.call(job:)
      return false unless job.cancellable?

      if job.queued?
        job.transaction do
          job.leases.active.find_each { |lease| lease.release!("cancelled") }
          job.finish_with!(
            termination_reason: "cancelled",
            stderr: "管理画面から中断されました",
            applied_limits: job.limits
          )
        end
      else
        # Reaches the worker on the next job heartbeat, within HEARTBEAT_INTERVAL seconds
        job.update!(cancel_requested_at: Time.current)
      end

      true
    end
  end
end
