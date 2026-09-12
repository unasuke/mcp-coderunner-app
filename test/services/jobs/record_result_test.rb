require "test_helper"

class Jobs::RecordResultTest < ActiveSupport::TestCase
  setup do
    dockerfile = "FROM ruby:3.4-slim\n"
    @blueprint = Blueprint.create!(name: "ruby", summary: "テスト用", dockerfile:, state: :approved,
      digest: Blueprint.digest_for(dockerfile:, files: []))
  end

  # An image that will not build will not build for the next job either. Making
  # each one discover that for itself costs a build apiece, twice over
  test "a build failure settles the jobs waiting on the same environment" do
    queued = job(state: :queued)
    waiting = job(profile: "bench")
    running = job(state: :running)

    record(job(state: :leased), "image_build_failed")

    assert_predicate queued.reload, :finished?
    assert_equal "image_build_failed", queued.job_result.termination_reason
    assert_match(/実行せずに終了/, queued.job_result.stderr)

    assert_predicate waiting.reload, :rejected?
    assert_nil waiting.approved_by

    # Mid-flight, and reports whatever it finds
    assert_predicate running.reload, :running?
  end

  test "a job that merely exited leaves its siblings alone" do
    queued = job(state: :queued)
    waiting = job(profile: "bench")

    record(job(state: :leased), "exited")

    assert_predicate queued.reload, :queued?
    assert_predicate waiting.reload, :pending_review?
  end

  # Another environment's failure says nothing about this one
  test "the sweep stops at the blueprint that failed" do
    other = Blueprint.create!(name: "other", summary: "x", dockerfile: "FROM a\n", state: :approved,
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []))
    untouched = Job.create!(blueprint: other, script: "puts 1", profile: "default", state: :queued)

    record(job(state: :leased), "image_build_failed")

    assert_predicate untouched.reload, :queued?
  end

  private

  def job(state: :pending_review, profile: "default")
    Job.create!(blueprint: @blueprint, script: "puts 1", profile:, state:)
  end

  def record(target, reason)
    _lease, token = Lease.issue!(job: target, instance_id: "i-1")
    Jobs::RecordResult.call(job: target, lease_token: token,
      attributes: { termination_reason: reason, applied_limits: {} })
  end
end
