# frozen_string_literal: true

require_relative "helper"
require "worker/runner"

class RunnerTest < Minitest::Test
  include WorkerTestHelper

  def setup
    @policy = build_policy(runtime_dir: "/tmp/mcp-coderunner-app-test")
    @runner = Worker::Runner.new(policy: @policy)
  end

  def args(payload: build_payload, applied: nil)
    applied ||= @policy.clamp(payload.limits)
    @runner.run_args(payload, applied:, tag: "mcp-coderunner-app/bp:#{payload.blueprint.digest}",
      workdir: "/run/mcp-coderunner-app/1042/work", container: "mcp-coderunner-app-1042-88")
  end

  def pair(list, flag)
    index = list.index(flag)
    index && list[index + 1]
  end

  def test_isolation_flags_are_always_present
    list = args

    assert_includes list, "--read-only"
    assert_equal "none", pair(list, "--network")
    assert_equal "ALL", pair(list, "--cap-drop")
    assert_equal "no-new-privileges", pair(list, "--security-opt")
    assert_equal "core=0", pair(list, "--ulimit")
  end

  # A script running on an approved Blueprint is not itself reviewed, so docker
  # holds a ceiling of its own to keep output from filling the host's disk
  def test_limits_the_container_log
    list = args

    assert_equal "json-file", pair(list, "--log-driver")
    assert_includes list, "max-size=256k"
    assert_includes list, "max-file=2"
  end

  # With --rm the container disappears as it exits, taking State.OOMKilled with it
  def test_does_not_remove_the_container_automatically
    refute_includes args, "--rm"
  end

  # Not set: it fails across the board on images without uid 1000, the official ruby ones included
  def test_does_not_pin_the_user
    refute_includes args, "--user"
  end

  def test_applies_the_clamped_limits
    list = args

    assert_equal "2048m", pair(list, "--memory")
    assert_equal "2048m", pair(list, "--memory-swap")
    assert_equal "2", pair(list, "--cpus")
    assert_equal "512", pair(list, "--pids-limit")
    assert_equal "/tmp:rw,size=512m,mode=1777", pair(list, "--tmpfs")
  end

  def test_mounts_the_work_directory_read_only
    assert_equal "/run/mcp-coderunner-app/1042/work:/work:ro", pair(args, "--volume")
  end

  def test_labels_the_container_for_orphan_cleanup
    assert_equal "mcp-coderunner-app.job=1042", pair(args, "--label")
  end

  def test_entrypoint_comes_last_and_defaults_to_ruby
    assert_equal [ "ruby", "/work/script.rb" ], args.last(2)
    assert_equal [ "bundle", "exec", "ruby", "/work/script.rb" ],
      args(payload: build_payload(entrypoint: [ "bundle", "exec", "ruby", "/work/script.rb" ])).last(4)
  end

  def test_image_tag_precedes_the_entrypoint
    list = args

    payload = build_payload
    list = args(payload:)

    assert_equal "mcp-coderunner-app/bp:#{payload.blueprint.digest}", list[list.index("ruby") - 1]
  end

  # Exclusive jobs are kept alone by the serialization on both sides, not by pinning.
  # A rootless daemon is not delegated the cpuset controller, so the flag would be
  # taken, discarded with a warning, and that warning would land in the stderr of the
  # job being measured
  def test_bench_is_not_pinned_to_a_cpuset
    payload = build_payload(profile: "bench",
      limits: { "memory_mb" => 4096, "cpus" => 4, "pids" => 1024, "timeout_s" => 300, "tmpfs_mb" => 1024 })
    policy = build_policy(limits: { "max_cpus" => 4, "max_memory_mb" => 4096, "max_tmpfs_mb" => 1024 })
    list = Worker::Runner.new(policy:).run_args(payload, applied: policy.clamp(payload.limits),
      tag: "mcp-coderunner-app/bp:x", workdir: "/w", container: "c")

    refute_includes list, "--cpuset-cpus"
    assert_equal "4", pair(list, "--cpus")
  end

  # Even when a bug in the worker lets an exception out, a result always goes back
  def test_unexpected_errors_come_back_as_worker_error
    builder = Object.new
    def builder.ensure_image!(**) = raise(TypeError, "boom")
    runner = Worker::Runner.new(policy: @policy, builder:)

    result = runner.call(build_payload)

    assert_equal "worker_error", result.termination_reason
    assert_includes result.stderr, "TypeError: boom"
  end

  # Fail on a tag that is not already local, rather than pulling a same-named image from the Hub
  def test_never_pulls
    assert_equal "never", pair(args, "--pull")
  end

  # The digest is the unit approval is granted in. Recompute it from the content; a mismatch does not run
  def test_rejects_a_digest_that_does_not_match_the_context
    payload = build_payload(digest: "b" * 64)

    result = @runner.call(payload)

    assert_equal "policy_rejected", result.termination_reason
    assert_includes result.stderr, "digest does not match"
  end

  def test_rejects_a_digest_that_is_not_hex
    payload = build_payload(digest: "sha256:deadbeef")

    result = @runner.call(payload)

    assert_equal "policy_rejected", result.termination_reason
  end

  # Identifiers from the VPS go straight into a path and a container name, so check their shape first
  def test_rejects_identifiers_that_are_not_numeric
    payload = build_payload
    payload.instance_variable_set(:@job_id, "../../etc")

    result = @runner.call(payload)

    assert_equal "policy_rejected", result.termination_reason
  end
end
