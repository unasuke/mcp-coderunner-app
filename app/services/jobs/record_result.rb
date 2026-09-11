module Jobs
  # 結果はジョブに 1 行だけ。lease が失効していたら 409 で拒否する。
  # 二重実行が起きても、DB に入るのは生き残った側の結果だけになる。
  class RecordResult
    Conflict = Class.new(StandardError)

    def self.call(job:, lease_token:, attributes:)
      # 認証もトランザクションの中でやり直す。確認したあとに別の経路で
      # 解放されていると、失効したリースの結果を受け入れてしまう
      Job.transaction do
        lease = job.leases.active.first
        raise Conflict, "lease is not active" unless lease&.authenticate(lease_token)

        job.finish_with!(attributes.merge(worker_id: worker_id_for(lease)))
        lease.release!("completed")
        job.job_result
      end
    rescue ActiveRecord::RecordNotUnique
      # 結果はジョブに 1 行だけ。二重送信は 409 であって 500 ではない
      raise Conflict, "a result is already recorded"
    end

    def self.worker_id_for(lease)
      WorkerProcess.find_by(instance_id: lease.instance_id)&.worker_id
    end
  end
end
