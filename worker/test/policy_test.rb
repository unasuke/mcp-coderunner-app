# frozen_string_literal: true

require_relative "helper"

class PolicyTest < Minitest::Test
  include WorkerTestHelper

  def setup
    @policy = build_policy(limits: { "max_memory_mb" => 2048, "max_cpus" => 2, "max_timeout_s" => 120 })
  end

  def test_clamps_values_that_exceed_the_local_maximum
    applied = @policy.clamp({ memory_mb: 8192, cpus: 8, pids: 4096, timeout_s: 600, tmpfs_mb: 4096 })

    assert_equal 2048, applied.fetch(:memory_mb)
    assert_equal 2, applied.fetch(:cpus)
    assert_equal 1024, applied.fetch(:pids)
    assert_equal 120, applied.fetch(:timeout_s)
  end

  def test_keeps_values_below_the_local_maximum
    applied = @policy.clamp({ memory_mb: 512, cpus: 1, pids: 128, timeout_s: 30, tmpfs_mb: 64 })

    assert_equal({ memory_mb: 512, cpus: 1, pids: 128, timeout_s: 30, tmpfs_mb: 64 }, applied)
  end

  def test_missing_values_fall_back_to_the_local_maximum
    applied = @policy.clamp({})

    assert_equal 2048, applied.fetch(:memory_mb)
  end

  def test_rejects_paths_that_escape_the_context
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("../secret") }
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("a/../../secret") }
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("/etc/passwd") }
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("a\\b") }
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("") }
    assert_raises(Worker::PolicyRejected) { @policy.validate_path!("a" * 256) }
  end

  def test_accepts_ordinary_relative_paths
    assert @policy.validate_path!("Gemfile")
    assert @policy.validate_path!("config/boot.rb")
    assert @policy.validate_path!("a..b")
  end

  def test_rejects_context_over_the_limit
    policy = build_policy(limits: { "max_context_bytes" => 32 })
    files = [ Protocol::JobPayload::ContextFile.new(path: "a", content: "x" * 64, executable: false) ]

    assert_raises(Worker::PolicyRejected) { policy.validate_context!("FROM ruby", files) }
  end

  def test_reads_the_token_from_a_systemd_credential
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "api_token"), "secret\n")
      ENV["CREDENTIALS_DIRECTORY"] = dir

      assert_equal "secret", build_policy(token_file: "/nonexistent").token
    ensure
      ENV.delete("CREDENTIALS_DIRECTORY")
    end
  end
end
