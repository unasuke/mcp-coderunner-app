require "test_helper"

class RetentionJobTest < ActiveSupport::TestCase
  setup do
    @blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
  end

  def finished_job(created_at:)
    Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :finished,
      created_at:, updated_at: created_at)
  end

  # script は not null のまま。消したことは purged_at で表す
  test "old scripts are emptied and stamped" do
    old = finished_job(created_at: 100.days.ago)
    recent = finished_job(created_at: 1.day.ago)

    RetentionJob.new.perform

    assert_equal "", old.reload.script
    assert_predicate old, :purged?
    assert_equal "puts 1", recent.reload.script
    refute_predicate recent, :purged?
  end

  # 行ごと消すと termination_reason まで失われ、get_job が「まだ結果が無い」と
  # 見分けがつかなくなる
  test "old outputs are emptied but the reason survives" do
    job = finished_job(created_at: 100.days.ago)
    JobResult.create!(job:, termination_reason: "oom_killed", exit_code: 137, stdout: "x" * 100,
      stderr: "y", truncated: true, applied_limits: { "memory_mb" => 2048 }, created_at: 40.days.ago)

    RetentionJob.new.perform

    result = job.reload.job_result

    assert_equal "oom_killed", result.termination_reason
    assert_equal 137, result.exit_code
    assert_equal "", result.stdout
    assert_equal "", result.stderr
    refute_predicate result, :truncated?
    assert_predicate job, :purged?
  end

  test "recent outputs are left alone" do
    job = finished_job(created_at: 1.day.ago)
    JobResult.create!(job:, termination_reason: "exited", stdout: "keep me", applied_limits: {})

    RetentionJob.new.perform

    assert_equal "keep me", job.reload.job_result.stdout
    refute_predicate job, :purged?
  end

  # アクセストークンは 15 分で切れるが、リフレッシュには寿命が無い
  test "refresh tokens are revoked once they go unused" do
    application = Doorkeeper::Application.create!(name: "claude", redirect_uri: "https://claude.invalid/cb",
      confidential: false, scopes: "")
    user = User.create!(github_uid: "1", login: "unasuke", role: :member)
    stale = Doorkeeper::AccessToken.create!(application:, resource_owner_id: user.id, expires_in: 900,
      scopes: "mcp", use_refresh_token: true, created_at: 40.days.ago)
    fresh = Doorkeeper::AccessToken.create!(application:, resource_owner_id: user.id, expires_in: 900,
      scopes: "mcp", use_refresh_token: true)

    RetentionJob.new.perform

    assert_predicate stale.reload, :revoked?
    refute_predicate fresh.reload, :revoked?
  end

  test "released leases and stopped processes are cleaned up" do
    job = finished_job(created_at: 1.day.ago)
    lease, = Lease.issue!(job:, instance_id: "old")
    lease.update!(released_at: 40.days.ago, release_reason: "completed")
    WorkerProcess.create!(worker_id: "vm", instance_id: "old", commit_hash: "abc", protocol_version: 1,
      capacity: 1, started_at: 41.days.ago, last_heartbeat_at: 41.days.ago, stopped_at: 40.days.ago)

    RetentionJob.new.perform

    assert_equal 0, Lease.count
    assert_equal 0, WorkerProcess.count
  end
end
