module Jobs
  # 結果はジョブに 1 行だけ。lease が失効していたら 409 で拒否する。
  # 二重実行が起きても、DB に入るのは生き残った側の結果だけになる。
  class RecordResult
    Conflict = Class.new(StandardError)

    def self.call(job:, lease_token:, attributes:)
      lease = job.active_lease
      raise Conflict, "lease is not active" unless lease&.authenticate(lease_token)

      Job.transaction do
        job.finish_with!(attributes.merge(worker_id: worker_id_for(lease)))
        lease.release!("completed")
      end
      job.job_result
    end

    def self.worker_id_for(lease)
      WorkerProcess.find_by(instance_id: lease.instance_id)&.worker_id
    end
  end
end
