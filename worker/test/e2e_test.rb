# frozen_string_literal: true

# The only test that actually drives docker. Runs only under MCP_CODERUNNER_APP_E2E=1.
#
# Keeping it to one is not only about how slow it is: it holds the grain at which a
# failure still points at one place. It watches two things -- that --network none
# holds, and that statistics come back from the cgroup.

require_relative "helper"
require "worker/runner"

class E2eTest < Minitest::Test
  include WorkerTestHelper

  SCRIPT = <<~SH
    echo "hello from the container"
    if wget -q -T 2 -O - http://example.com >/dev/null 2>&1; then
      echo "network reachable"
    else
      echo "network unreachable"
    fi
    head -c 20000000 /dev/zero | tail -c 1 >/dev/null
  SH

  def setup
    skip "set MCP_CODERUNNER_APP_E2E=1 to run" unless ENV["MCP_CODERUNNER_APP_E2E"] == "1"
  end

  def test_builds_runs_and_reports
    Dir.mktmpdir do |runtime_dir|
      policy = build_policy(runtime_dir:)
      payload = build_payload(entrypoint: [ "sh", "/work/script.rb" ],
        dockerfile: "FROM alpine:3.20\n", script: SCRIPT)

      result = Worker::Runner.new(policy:).call(payload)

      assert_equal "exited", result.termination_reason, result.stderr
      assert_equal 0, result.exit_code
      assert_includes result.stdout, "hello from the container"
      # --network none, no exceptions
      assert_includes result.stdout, "network unreachable"
      # statistics came back from the cgroup
      refute_nil result.cpu_time_ms
      refute_nil result.max_rss_bytes
      assert_operator result.max_rss_bytes, :>, 0
      assert_match(/\Asha256:/, result.image_digest)
      assert_equal 2048, result.applied_limits.fetch(:memory_mb)
    end
  end

  def test_timeout_is_reported_as_timeout
    Dir.mktmpdir do |runtime_dir|
      policy = build_policy(runtime_dir:, limits: { "max_timeout_s" => 3 })
      payload = build_payload(entrypoint: [ "sh", "/work/script.rb" ],
        dockerfile: "FROM alpine:3.20\n", script: "sleep 60\n")

      result = Worker::Runner.new(policy:).call(payload)

      assert_equal "timeout", result.termination_reason
    end
  end
end
