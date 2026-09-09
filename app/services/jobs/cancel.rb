module Jobs
  # キャンセルは queued 以降のすべての状態で押せる（pending_review は却下で終わらせる）。
  #
  # leased 以降で即座に止められないのは、ワーカーへ命令を送る経路が heartbeat しか
  # ないため。自宅側に inbound の口を開けない以上ここは動かせない。
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
        # 次の job heartbeat（最長 HEARTBEAT_INTERVAL 秒）でワーカーに伝わる
        job.update!(cancel_requested_at: Time.current)
      end

      true
    end
  end
end
