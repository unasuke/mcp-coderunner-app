require "test_helper"

class Jobs::ClaimTest < ActiveSupport::TestCase
  setup do
    dockerfile = "FROM ruby:3.4-slim\n"
    @blueprint = Blueprint.create!(name: "ruby", summary: "test", dockerfile:,
      digest: Blueprint.digest_for(dockerfile:, files: []), state: :approved)
  end

  def job(profile: "default", state: :queued, **attributes)
    Job.create!(blueprint: @blueprint, script: "puts 1", profile:, state:, **attributes)
  end

  def claim
    Jobs::Claim.call(instance_id: "0190a1b2-0000-7000-8000-000000000001")
  end

  test "claims the oldest queued job" do
    first = job
    job

    assert_equal first, claim.job
    assert_equal "leased", first.reload.state
  end

  test "claims nothing when the queue is empty" do
    assert_nil claim
  end

  # Another job running alongside bench ruins the measurement, and the result still looks fine
  test "hands out nothing at all while an exclusive job runs" do
    job(profile: "bench", state: :running)
    job(profile: "default")
    job(profile: "bench")

    assert_nil claim
  end

  # bench starts only when nothing else is running
  test "holds back an exclusive job while anything else runs" do
    job(profile: "default", state: :running)
    bench = job(profile: "bench")
    queued = job(profile: "default")

    claimed = claim

    assert_equal queued, claimed.job
    assert_equal "queued", bench.reload.state
  end

  test "hands out an exclusive job once nothing is running" do
    bench = job(profile: "bench")

    assert_equal bench, claim.job
  end

  # A job someone asked to stop is not picked back up
  test "skips a job that has been asked to cancel" do
    job(cancel_requested_at: Time.current)

    assert_nil claim
  end
end
