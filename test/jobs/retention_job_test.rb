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

  test "old results are deleted" do
    job = finished_job(created_at: 100.days.ago)
    JobResult.create!(job:, termination_reason: "exited", applied_limits: {}, created_at: 40.days.ago)

    RetentionJob.new.perform

    assert_nil job.reload.job_result
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
