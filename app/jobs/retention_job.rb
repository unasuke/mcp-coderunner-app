# Job payloads and results accumulate on the VPS in the clear. Nothing secret can
# structurally end up in them, but the disk still fills. Runs daily.
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

  # An access token expires in 15 minutes, but a refresh token has no lifetime of
  # its own. Every rotation writes a new row, so created_at is when it was last used
  def revoke_stale_refresh_tokens(now, retention)
    Doorkeeper::AccessToken
      .where(revoked_at: nil)
      .where.not(refresh_token: nil)
      .where(created_at: ...(now - retention))
      .find_each(&:revoke)
  end

  # What eats the disk is stdout and stderr (up to 256KB each); the row itself is
  # small. Deleting the row would take termination_reason with it, leaving get_job
  # unable to tell this apart from "no result yet". Empty the body instead, and say
  # so through purged_at
  def purge_outputs(now, retention)
    JobResult.where(created_at: ...(now - retention)).find_each do |result|
      next if result.stdout.blank? && result.stderr.blank?

      result.update_columns(stdout: "", stderr: "", truncated: false)
      result.job.update_columns(purged_at: now) if result.job.purged_at.nil?
    end
  end

  # script stays not null, and purged_at is what says it was cleared -- so that
  # "deleted" and "empty to begin with" are not mistaken for each other
  def purge_scripts(now, retention)
    Job.finished.where.not(script: "").where(created_at: ...(now - retention)).find_each do |job|
      job.update_columns(script: "", purged_at: job.purged_at || now)
    end
  end
end
