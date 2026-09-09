# 10 秒ごとに 2 つを走査する。
#
#   1. heartbeat が途絶えた worker_processes を死んだものとみなし、
#      その instance が持っていたリースを即座に失効させる
#   2. 期限切れのリースを回収する
#
# 1 があると、ワーカーがクラッシュしたときにリースのタイムアウトを待たずに済む。
class LeaseReaperJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    reap_stale_processes(now)
    reap_expired_leases(now)
  end

  private

  def reap_stale_processes(now)
    WorkerProcess.stale(now).find_each do |process|
      Lease.active.held_by(process.instance_id).find_each do |lease|
        Jobs::ReleaseLease.call(lease:, reason: "expired")
      end
      process.stop!
    end
  end

  def reap_expired_leases(now)
    Lease.expired(now).find_each do |lease|
      Jobs::ReleaseLease.call(lease:, reason: "expired")
    end
  end
end
