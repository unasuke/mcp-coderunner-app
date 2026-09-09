# frozen_string_literal: true

# 実際に docker を回す唯一のテスト。MCPRB_E2E=1 のときだけ走る。
#
# 1 本に絞るのは遅いからだけではなく、壊れたときに原因が 1 箇所に絞れる粒度を保つため。
# 見ているのは 2 つ、--network none が効いていることと、cgroup から統計が取れること。

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
    skip "set MCPRB_E2E=1 to run" unless ENV["MCPRB_E2E"] == "1"
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
      # --network none は例外なし
      assert_includes result.stdout, "network unreachable"
      # cgroup から統計が取れている
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
