module Jobs
  # リースを解放してジョブの行き先を決める。
  #
  # /deregister（正常な再起動）は試行回数を見ずに queued に戻す。更新のたびに
  # 走りかけのジョブが捨てられるのは実用的でない。失効した場合だけ回数を見る。
  class ReleaseLease
    def self.call(lease:, reason:, requeue_always: false)
      job = lease.job
      lease.release!(reason)
      return job if job.finished?

      if requeue_always || job.retriable?
        job.update!(state: :queued)
      else
        job.finish_with!(
          termination_reason: "lease_expired",
          stderr: "ワーカーが応答しなくなりました（試行 #{job.attempts} 回）",
          applied_limits: job.limits
        )
      end
      job
    end
  end
end
