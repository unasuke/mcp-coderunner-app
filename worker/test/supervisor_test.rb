# frozen_string_literal: true

require_relative "helper"
require "worker/supervisor"

class SupervisorTest < Minitest::Test
  Stats = Struct.new(:oom_kills, :pids_max_events, keyword_init: true)

  def reason(state: nil, killed_by: nil, stats: nil)
    Worker::Supervisor.termination_reason(state:, killed_by:, stats:)
  end

  def test_supervisor_kill_wins_over_everything
    # Memory pressure right after a timeout's SIGKILL would otherwise be recorded as an OOM
    state = { "OOMKilled" => true, "ExitCode" => 137 }

    assert_equal "timeout", reason(state:, killed_by: :timeout, stats: Stats.new(oom_kills: 1, pids_max_events: 0))
    assert_equal "cancelled", reason(state:, killed_by: :cancelled)
  end

  def test_oom_from_docker_state
    assert_equal "oom_killed", reason(state: { "OOMKilled" => true, "ExitCode" => 137 })
  end

  # When only a child is OOM-killed the container survives, and State.OOMKilled reads false
  def test_oom_from_cgroup_when_docker_state_is_false
    state = { "OOMKilled" => false, "ExitCode" => 1 }

    assert_equal "oom_killed", reason(state:, stats: Stats.new(oom_kills: 1, pids_max_events: 0))
  end

  def test_pids_exceeded
    state = { "OOMKilled" => false, "ExitCode" => 1 }

    assert_equal "pids_exceeded", reason(state:, stats: Stats.new(oom_kills: 0, pids_max_events: 3))
  end

  def test_plain_exit
    assert_equal "exited", reason(state: { "OOMKilled" => false, "ExitCode" => 0 })
    assert_equal "exited", reason(state: { "OOMKilled" => false, "ExitCode" => 1 })
  end

  def test_missing_state_does_not_blow_up
    assert_equal "exited", reason(state: nil, stats: nil)
  end

  def test_disk_full_detection
    assert Worker::Supervisor.disk_full?("sh: write error: No space left on device")
    refute Worker::Supervisor.disk_full?("undefined method `foo'")
    refute Worker::Supervisor.disk_full?(nil)
  end
end
