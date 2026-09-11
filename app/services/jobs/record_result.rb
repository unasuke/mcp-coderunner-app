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
        job.job_result
      end
    rescue ActiveRecord::RecordNotUnique
      # One result row per job. A double send is a 409, not a 500
      raise Conflict, "a result is already recorded"
    end

    def self.worker_id_for(lease)
      WorkerProcess.find_by(instance_id: lease.instance_id)&.worker_id
    end
  end
end
