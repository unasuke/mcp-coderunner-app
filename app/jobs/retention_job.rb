# ジョブのペイロードと結果は VPS 上に平文で溜まる。秘匿情報は構造的に入らないが、
# ディスクは埋まる。日次で回す。
class RetentionJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    config = Rails.configuration.x.mcp_coderunner_app

    revoke_stale_refresh_tokens(now, config.refresh_token_retention_days.days)
    purge_outputs(now, config.result_retention_days.days)
    purge_scripts(now, config.script_retention_days.days)
    WorkerProcess.where(stopped_at: ...(now - config.process_retention_days.days)).delete_all
    Lease.where(released_at: ...(now - config.lease_retention_days.days)).delete_all
  end

  private

  # アクセストークンは 15 分で切れるが、リフレッシュには寿命が無い。
  # ローテーションのたびに行が作り直されるので、created_at が最後に使われた時刻になる
  def revoke_stale_refresh_tokens(now, retention)
    Doorkeeper::AccessToken
      .where(revoked_at: nil)
      .where.not(refresh_token: nil)
      .where(created_at: ...(now - retention))
      .find_each(&:revoke)
  end

  # ディスクを食っているのは stdout と stderr（各 256KB まで）で、行そのものは小さい。
  # 行ごと消すと termination_reason まで失われ、get_job が「まだ結果が無い」と
  # 見分けがつかなくなる。本文だけ空にして、消したことは purged_at で表す
  def purge_outputs(now, retention)
    JobResult.where(created_at: ...(now - retention)).find_each do |result|
      next if result.stdout.blank? && result.stderr.blank?

      result.update_columns(stdout: "", stderr: "", truncated: false)
      result.job.update_columns(purged_at: now) if result.job.purged_at.nil?
    end
  end

  # script は not null のままにする。消したことは purged_at で表す。
  # 「消した」と「元々空だった」を取り違えないため
  def purge_scripts(now, retention)
    Job.finished.where.not(script: "").where(created_at: ...(now - retention)).find_each do |job|
      job.update_columns(script: "", purged_at: job.purged_at || now)
    end
  end
end
