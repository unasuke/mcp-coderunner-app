require "test_helper"

class WorkerApiTest < ActionDispatch::IntegrationTest
  INSTANCE_ID = "0190a1b2-0000-7000-8000-000000000001".freeze

  setup do
    @worker, @token = Worker.issue!(worker_id: "test-vm")
    @blueprint = Blueprint.create!(name: "ruby", summary: "test", dockerfile: "FROM ruby:3.4-slim\n",
      digest: Blueprint.digest_for(dockerfile: "FROM ruby:3.4-slim\n", files: []), state: :approved)
    @job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :queued)
  end

  def auth_headers(token = @token)
    { "Authorization" => "Bearer #{token}" }
  end

  def register!
    post "/api/worker/v1/register", headers: auth_headers, as: :json, params: {
      worker_id: @worker.worker_id, instance_id: INSTANCE_ID, commit_hash: "abc123",
      protocol_version: Protocol::Constants::PROTOCOL_VERSION, capacity: 2,
      hostname: "vm", pid: 1234, ruby_version: "3.4.1", docker_version: "27.3.1"
    }
  end

  test "unknown token is rejected" do
    post "/api/worker/v1/register", headers: auth_headers("nope"), as: :json, params: {}

    assert_response :unauthorized
  end

  test "revoked worker is rejected" do
    @worker.revoke!
    register!

    assert_response :unauthorized
  end

  # The worker_id comes from the token. Nothing a client says about itself in the
  # body can pass it off as a different worker
  test "worker_id mismatch is rejected" do
    post "/api/worker/v1/register", headers: auth_headers, as: :json, params: {
      worker_id: "someone-else", instance_id: INSTANCE_ID, commit_hash: "abc",
      protocol_version: 1, capacity: 1
    }

    assert_response :unauthorized
  end

  test "register creates a process and reports the server commit" do
    register!

    assert_response :success
    assert_equal Protocol::Constants::PROTOCOL_VERSION, response.parsed_body["protocol_version"]
    assert WorkerProcess.find_by(instance_id: INSTANCE_ID)
  end

  test "the full lease, heartbeat and result flow" do
    register!

    post "/api/worker/v1/lease", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: Protocol::Constants::PROTOCOL_VERSION }

    assert_response :success
    lease = response.parsed_body
    assert_equal @job.id, lease["job_id"]
    assert_equal @blueprint.digest, lease.dig("blueprint", "digest")
    assert_equal [ "ruby", "/work/script.rb" ], lease["entrypoint"]
    assert_equal 2048, lease.dig("limits", "memory_mb")
    assert_equal "leased", @job.reload.state

    # The first job heartbeat moves it to running
    post "/api/worker/v1/jobs/#{@job.id}/heartbeat", headers: auth_headers, as: :json,
      params: { lease_token: lease["lease_token"] }

    assert_response :success
    refute response.parsed_body["cancel"]
    assert_equal "running", @job.reload.state

    post "/api/worker/v1/jobs/#{@job.id}/result", headers: auth_headers, as: :json, params: {
      lease_token: lease["lease_token"], termination_reason: "exited", exit_code: 0,
      stdout: "1\n", stderr: "", truncated: false, duration_ms: 1200, cpu_time_ms: 40,
      max_rss_bytes: 17_000_000, image_digest: "sha256:abc",
      applied_limits: { memory_mb: 2048, cpus: 2, pids: 512, timeout_s: 60, tmpfs_mb: 512 }
    }

    assert_response :success
    assert_equal "finished", @job.reload.state
    assert_equal "exited", @job.job_result.termination_reason
    assert_equal "test-vm", @job.job_result.worker_id
    assert_equal "completed", @job.leases.first.release_reason
  end

  # Keeps the result of a double run from overwriting the real one
  test "a stale lease token is refused with 409" do
    register!
    post "/api/worker/v1/lease", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: Protocol::Constants::PROTOCOL_VERSION }
    token = response.parsed_body["lease_token"]

    @job.leases.first.release!("expired")

    post "/api/worker/v1/jobs/#{@job.id}/result", headers: auth_headers, as: :json,
      params: { lease_token: token, termination_reason: "exited", exit_code: 0, applied_limits: {} }

    assert_response :conflict
    assert_nil @job.reload.job_result
  end

  # The two sides cannot hold a conversation, so leasing stops
  test "a protocol mismatch stops leasing and drains" do
    register!

    post "/api/worker/v1/lease", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: 999 }

    assert_response :conflict

    post "/api/worker/v1/heartbeat", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: 999, commit_hash: "abc123" }

    assert_response :success
    assert response.parsed_body["drain"]
  end

  # An orderly restart requeues without consulting the attempt count
  test "deregister releases held leases and requeues" do
    register!
    post "/api/worker/v1/lease", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: Protocol::Constants::PROTOCOL_VERSION }

    post "/api/worker/v1/deregister", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, reason: "shutdown" }

    assert_response :success
    assert_equal [ @job.id ], response.parsed_body["released_jobs"]
    assert_equal "queued", @job.reload.state
    assert_equal "deregistered", @job.leases.first.release_reason
    assert_predicate WorkerProcess.find_by(instance_id: INSTANCE_ID).stopped_at, :present?
  end

  # A process that crashed never called /deregister. The cleanup in register is
  # where an unclean exit lands, so unless it consumes an attempt the same job gets
  # picked up forever
  test "re-registering after a crash counts the attempt" do
    register!
    post "/api/worker/v1/lease", headers: auth_headers, as: :json,
      params: { instance_id: INSTANCE_ID, protocol_version: Protocol::Constants::PROTOCOL_VERSION }

    assert_equal "leased", @job.reload.state

    post "/api/worker/v1/register", headers: auth_headers, as: :json, params: {
      worker_id: @worker.worker_id, instance_id: "#{INSTANCE_ID}-2", commit_hash: "abc123",
      protocol_version: Protocol::Constants::PROTOCOL_VERSION, capacity: 2
    }

    assert_response :success
    assert_equal "queued", @job.reload.state
    assert_equal "expired", @job.leases.order(:id).last.release_reason
    assert_equal 1, @job.leases.count
  end

  test "a crash loop gives up at the attempt limit" do
    Protocol::Constants::MAX_ATTEMPTS.times do |i|
      instance = "#{INSTANCE_ID}-#{i}"
      post "/api/worker/v1/register", headers: auth_headers, as: :json, params: {
        worker_id: @worker.worker_id, instance_id: instance, commit_hash: "abc123",
        protocol_version: Protocol::Constants::PROTOCOL_VERSION, capacity: 2
      }
      post "/api/worker/v1/lease", headers: auth_headers, as: :json,
        params: { instance_id: instance, protocol_version: Protocol::Constants::PROTOCOL_VERSION }
    end

    post "/api/worker/v1/register", headers: auth_headers, as: :json, params: {
      worker_id: @worker.worker_id, instance_id: "#{INSTANCE_ID}-last", commit_hash: "abc123",
      protocol_version: Protocol::Constants::PROTOCOL_VERSION, capacity: 2
    }

    assert_equal "finished", @job.reload.state
    assert_equal "lease_expired", @job.job_result.termination_reason
  end

  test "deregister is idempotent for unknown instances" do
    register!

    post "/api/worker/v1/deregister", headers: auth_headers, as: :json,
      params: { instance_id: "unknown", reason: "shutdown" }

    assert_response :success
    assert_equal [], response.parsed_body["released_jobs"]
  end

  test "no queued job returns 204 without waiting forever" do
    @job.destroy!
    register!

    stub_const(Protocol::Constants, :LEASE_WAIT, 0) do
      post "/api/worker/v1/lease", headers: auth_headers, as: :json,
        params: { instance_id: INSTANCE_ID, protocol_version: Protocol::Constants::PROTOCOL_VERSION }
    end

    assert_response :no_content
  end
end
