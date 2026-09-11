require "test_helper"

class LeaseReaperJobTest < ActiveSupport::TestCase
  setup do
    @blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    @job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :leased)
  end

  def register_process(instance_id:, last_heartbeat_at: Time.current)
    WorkerProcess.create!(worker_id: "vm", instance_id:, commit_hash: "abc", protocol_version: 1,
      capacity: 2, started_at: Time.current, last_heartbeat_at:)
  end

  # ワーカーがクラッシュしたときにリースのタイムアウトを待たずに済む
  test "a stale process loses its leases immediately" do
    register_process(instance_id: "dead", last_heartbeat_at: 5.minutes.ago)
    lease, = Lease.issue!(job: @job, instance_id: "dead")

    LeaseReaperJob.new.perform

    assert_equal "queued", @job.reload.state
    assert_equal "expired", lease.reload.release_reason
    assert_predicate WorkerProcess.find_by(instance_id: "dead").stopped_at, :present?
  end

  test "a live process keeps its lease" do
    register_process(instance_id: "alive")
    lease, = Lease.issue!(job: @job, instance_id: "alive")

    LeaseReaperJob.new.perform

    assert_equal "leased", @job.reload.state
    assert_predicate lease.reload, :active?
  end

  test "an expired lease is reclaimed and the job goes back to the queue" do
    register_process(instance_id: "alive")
    lease, = Lease.issue!(job: @job, instance_id: "alive")
    lease.update!(expires_at: 1.minute.ago)

    LeaseReaperJob.new.perform

    assert_equal "queued", @job.reload.state
    assert_equal "expired", lease.reload.release_reason
  end

  # 中断を要求したジョブを queued に戻すと、止めたはずのものが走り直す
  test "a cancelled job is finished rather than requeued" do
    register_process(instance_id: "alive")
    lease, = Lease.issue!(job: @job, instance_id: "alive")
    lease.update!(expires_at: 1.minute.ago)
    @job.update!(cancel_requested_at: Time.current)

    LeaseReaperJob.new.perform

    assert_equal "finished", @job.reload.state
    assert_equal "cancelled", @job.job_result.termination_reason
  end

  test "releasing a lease on a finished job does not send it back to the queue" do
    register_process(instance_id: "alive")
    lease, = Lease.issue!(job: @job, instance_id: "alive")
    lease.update!(expires_at: 1.minute.ago)
    @job.finish_with!(termination_reason: "exited", exit_code: 0, applied_limits: {})

    LeaseReaperJob.new.perform

    assert_equal "finished", @job.reload.state
    assert_equal "exited", @job.job_result.termination_reason
    assert_equal "expired", lease.reload.release_reason
  end

  # reaper と /deregister が同じリースに同時に来ても二重に動かさない
  test "releasing an already released lease is a no-op" do
    register_process(instance_id: "alive")
    lease, = Lease.issue!(job: @job, instance_id: "alive")
    lease.release!("completed")

    Jobs::ReleaseLease.call(lease:, reason: "expired")

    assert_equal "completed", lease.reload.release_reason
    assert_equal "leased", @job.reload.state
  end

  # 再試行の上限は「何が起きたか」ではなく「何回試したか」で持つ
  test "the job gives up after the attempt limit" do
    register_process(instance_id: "alive")
    Protocol::Constants::MAX_ATTEMPTS.times do
      lease, = Lease.issue!(job: @job, instance_id: "alive")
      lease.update!(expires_at: 1.minute.ago)
      LeaseReaperJob.new.perform
      @job.update!(state: :leased)
    end

    assert_equal Protocol::Constants::MAX_ATTEMPTS, @job.leases.count
    assert_equal "finished", @job.reload.state
    assert_equal "lease_expired", @job.job_result.termination_reason
  end
end
