module Jobs
  # Releases a lease and decides where the job goes next.
  #
  # /deregister -- an orderly restart -- requeues without looking at the attempt
  # count. Throwing away whatever was mid-flight on every update is no way to run
  # this. The count only matters when a lease actually expired.
  class ReleaseLease
    def self.call(lease:, reason:, requeue_always: false)
      # SQLite serializes writes, so one transaction is enough. With the release
      # and the state change visible separately, a job could be requeued twice
      Job.transaction do
        held = Lease.find(lease.id)
        job = held.job

        # Already released: do nothing. The reaper and /deregister arriving together act once
        next job unless held.active?

        held.release!(reason)
        next job if job.finished? || job.rejected?

        decide(job, requeue_always)
        job
      end
    end

    # Requeuing a job someone asked to stop would start the stopped thing over again
    def self.decide(job, requeue_always)
      if job.cancel_requested?
        job.finish_with!(
          termination_reason: "cancelled",
          stderr: "管理画面から中断されました",
          applied_limits: job.limits
        )
      elsif requeue_always || job.retriable?
        job.update!(state: :queued)
      else
        job.finish_with!(
          termination_reason: "lease_expired",
          stderr: "ワーカーが応答しなくなりました（試行 #{job.attempts} 回）",
          applied_limits: job.limits
        )
      end
    end
    private_class_method :decide
  end
end
