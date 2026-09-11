module Jobs
  # リースを解放してジョブの行き先を決める。
  #
  # /deregister（正常な再起動）は試行回数を見ずに queued に戻す。更新のたびに
  # 走りかけのジョブが捨てられるのは実用的でない。失効した場合だけ回数を見る。
  class ReleaseLease
    def self.call(lease:, reason:, requeue_always: false)
      # SQLite は書き込みを直列化するので、1 トランザクションに入れれば足りる。
      # 解放と state の移動が別々に見えると、二重に requeue されうる
      Job.transaction do
        held = Lease.find(lease.id)
        job = held.job

        # 既に解放済みなら何もしない。reaper と /deregister が同時に来ても二重に動かさない
        next job unless held.active?

        held.release!(reason)
        next job if job.finished? || job.rejected?

        decide(job, requeue_always)
        job
      end
    end

    # 中断を要求されたジョブを queued に戻すと、止めたはずのものが走り直す
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
