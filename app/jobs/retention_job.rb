# ジョブのペイロードと結果は VPS 上に平文で溜まる。秘匿情報は構造的に入らないが、
# ディスクは埋まる。日次で回す。
class RetentionJob < ApplicationJob
  queue_as :default

  RESULT_RETENTION = 30.days
  SCRIPT_RETENTION = 90.days
  PROCESS_RETENTION = 30.days
  LEASE_RETENTION = 30.days

  def perform(now: Time.current)
    JobResult.where(created_at: ...(now - RESULT_RETENTION)).delete_all
    purge_scripts(now)
    WorkerProcess.where(stopped_at: ...(now - PROCESS_RETENTION)).delete_all
    Lease.where(released_at: ...(now - LEASE_RETENTION)).delete_all
  end

  private

  # script は not null のままにする。消したことは purged_at で表す。
  # 「消した」と「元々空だった」を取り違えないため
  def purge_scripts(now)
    Job.finished.where(purged_at: nil).where(created_at: ...(now - SCRIPT_RETENTION)).find_each do |job|
      job.update_columns(script: "", purged_at: now)
    end
  end
end
