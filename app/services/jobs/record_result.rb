module Jobs
  # One result row per job, and an expired lease is turned away with a 409.
  # Even if a job did run twice, only the surviving side's result is stored.
  class RecordResult
    Conflict = Class.new(StandardError)

    def self.call(job:, lease_token:, attributes:)
      # Authenticate inside the transaction as well. Released by another path
      # after the check, and the result of a dead lease would be accepted
      Job.transaction do
        lease = job.leases.active.first
        raise Conflict, "lease is not active" unless lease&.authenticate(lease_token)

        job.finish_with!(attributes.merge(worker_id: worker_id_for(lease)))
        lease.release!("completed")
        settle_siblings(job) if job.job_result.image_build_failed?
        job.job_result
      end
    rescue ActiveRecord::RecordNotUnique
      # One result row per job. A double send is a 409, not a 500
      raise Conflict, "a result is already recorded"
    end

    # An image that will not build will not build for anyone. Left alone, every
    # other job on the same Blueprint takes a lease in turn, spends minutes on the
    # same broken Dockerfile and comes back saying the same thing -- twice each, up
    # to MAX_ATTEMPTS. Settle them here instead, naming the job that found out.
    #
    # Nothing leased or running is touched; those are mid-flight and report what
    # they find. Nobody decided this, so the rejected ones carry no approved_by.
    #
    # A build can fail for a passing reason -- a slow mirror, a bad minute
    # upstream -- and then this ends jobs that would have worked. Submitting again
    # is cheap and the Blueprint stays approved, which is the better side to be
    # wrong on than rebuilding a broken image once per job.
    def self.settle_siblings(job)
      note = "実行環境のビルドがジョブ ##{job.id} で失敗したため、実行せずに終了しました"

      job.blueprint.jobs.pending_review.to_a.each { |sibling| sibling.reject!(by: nil) }

      job.blueprint.jobs.queued.to_a.each do |sibling|
        sibling.finish_with!(termination_reason: "image_build_failed", stderr: note,
          applied_limits: sibling.limits)
      end
    end

    def self.worker_id_for(lease)
      WorkerProcess.find_by(instance_id: lease.instance_id)&.worker_id
    end
  end
end
