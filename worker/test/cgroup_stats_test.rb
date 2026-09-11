# frozen_string_literal: true

require_relative "helper"
require "worker/cgroup_stats"

class CgroupStatsTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/cgroup", __dir__)

  def test_reads_cpu_memory_and_events
    stats = Worker::CgroupStats.new(1, base: FIXTURES).sample

    assert_equal 3980, stats.cpu_time_ms
    assert_equal 184_549_376, stats.max_rss_bytes
    assert_equal 1, stats.oom_kills
    assert_equal 3, stats.pids_max_events
  end

  # On a kernel without memory.peak, the highest memory.current seen while polling stands in
  def test_falls_back_to_memory_current
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "memory.current"), "12345\n")
      stats = Worker::CgroupStats.new(1, base: dir).sample

      assert_equal 12_345, stats.max_rss_bytes
    end
  end

  def test_max_rss_keeps_the_highest_sample
    Dir.mktmpdir do |dir|
      path = File.join(dir, "memory.current")
      stats = Worker::CgroupStats.new(1, base: dir)

      File.write(path, "500\n")
      stats.sample
      File.write(path, "100\n")
      stats.sample

      assert_equal 500, stats.max_rss_bytes
    end
  end

  # Failing to measure a run is not the same as the run failing. Every read is best-effort
  def test_missing_files_are_ignored
    Dir.mktmpdir do |dir|
      stats = Worker::CgroupStats.new(1, base: dir).sample

      assert_nil stats.cpu_time_ms
      assert_nil stats.max_rss_bytes
      assert_equal 0, stats.oom_kills
    end
  end

  def test_missing_process_resolves_to_no_base
    assert_nil Worker::CgroupStats.resolve_base(999_999_999)
  end

  # A container that ends at once is already gone from /proc. Dying here would leave the job hanging
  def test_start_and_stop_are_safe_without_a_resolvable_cgroup
    stats = Worker::CgroupStats.new(999_999_999)

    assert_same stats, stats.start
    assert_same stats, stats.stop
    assert_nil stats.cpu_time_ms
  end
end
