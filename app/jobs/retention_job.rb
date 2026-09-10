# ジョブのペイロードと結果は VPS 上に平文で溜まる。秘匿情報は構造的に入らないが、
# ディスクは埋まる。日次で回す。
class RetentionJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    config = Rails.configuration.x.mcp_coderunner_app

    JobResult.where(created_at: ...(now - config.result_retention_days.days)).delete_all
    purge_scripts(now, config.script_retention_days.days)
    WorkerProcess.where(stopped_at: ...(now - config.process_retention_days.days)).delete_all
    Lease.where(released_at: ...(now - config.lease_retention_days.days)).delete_all
  end

  private

  # script は not null のままにする。消したことは purged_at で表す。
  # 「消した」と「元々空だった」を取り違えないため
  def purge_scripts(now, retention)
    Job.finished.where(purged_at: nil).where(created_at: ...(now - retention)).find_each do |job|
      job.update_columns(script: "", purged_at: now)
    end
  end
end
