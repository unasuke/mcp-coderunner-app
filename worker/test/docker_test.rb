# frozen_string_literal: true

require_relative "helper"
require "worker/docker"

class DockerTest < Minitest::Test
  # A build runs for minutes. Without this the worker sits in capture3 until the
  # shutdown grace runs out, then leaves the build running behind it
  def test_a_cancelled_command_is_killed_rather_than_waited_out
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Worker::Docker.run("30", command: "sleep", cancelled: -> { true })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_predicate result, :success?
    assert_operator elapsed, :<, 5, "waited #{elapsed}s for a command it was told to stop"
  end

  def test_a_command_that_is_not_cancelled_runs_to_the_end
    result = Worker::Docker.run("-c", "printf out; printf err >&2", command: "sh",
      cancelled: -> { false })

    assert_predicate result, :success?
    assert_equal "out", result.stdout
    assert_equal "err", result.stderr
  end

  def test_output_survives_a_command_that_says_more_than_a_pipe_holds
    result = Worker::Docker.run("-c", "yes x | head -c 200000", command: "sh",
      cancelled: -> { false })

    assert_predicate result, :success?
    assert_equal 200_000, result.stdout.bytesize
  end

  def test_a_missing_command_is_a_docker_error
    assert_raises(Worker::DockerError) { Worker::Docker.run("x", command: "definitely-not-here") }
  end
end
