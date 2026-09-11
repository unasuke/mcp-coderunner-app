# frozen_string_literal: true

require "worker/docker"

module Worker
  # Watches the wall clock and the cancel flag, and decides how a job ended.
  #
  # Ruby can swallow a signal, so docker stop alone is not enough. Send SIGTERM,
  # give it a moment, and kill whatever is still standing.
  class Supervisor
    POLL_INTERVAL = 0.2
    STOP_GRACE = 5

    DISK_FULL_PATTERNS = [
      /No space left on device/i,
      /ENOSPC/
    ].freeze

    attr_reader :killed_by

    def initialize(container:, timeout_s:, cancelled: nil, poll_interval: POLL_INTERVAL, stop_grace: STOP_GRACE)
      @container = container
      @timeout_s = timeout_s
      @cancelled = cancelled || -> { false }
      @poll_interval = poll_interval
      @stop_grace = stop_grace
      @killed_by = nil
    end

    # Waits for the container to finish. Returns :exited, :timeout or :cancelled
    def wait
      deadline = monotonic + @timeout_s

      loop do
        return :exited unless running?

        if monotonic >= deadline
          @killed_by = :timeout
          terminate!
          return :timeout
        end

        if @cancelled.call
          @killed_by = :cancelled
          terminate!
          return :cancelled
        end

        sleep @poll_interval
      end
    end

    def running?
      result = Docker.run("inspect", "--format", "{{.State.Running}}", @container)
      return false unless result.success?

      result.stdout.strip == "true"
    end

    def terminate!
      Docker.run("stop", "-t", @stop_grace, @container)
      Docker.run("kill", @container) if running?
    end

    # The order of these checks carries meaning: what the supervisor did comes
    # first. Memory pressure right after a timeout's SIGKILL would otherwise be
    # recorded as an OOM that never happened.
    def self.termination_reason(state:, killed_by: nil, stats: nil)
      return "timeout" if killed_by == :timeout
      return "cancelled" if killed_by == :cancelled

      oom_kills = stats&.oom_kills.to_i
      pids_events = stats&.pids_max_events.to_i

      if (state && state["OOMKilled"]) || oom_kills.positive?
        "oom_killed"
      elsif pids_events.positive?
        "pids_exceeded"
      else
        "exited"
      end
    end

    # Nothing about this reaches the cgroup, so it is inferred from stderr. Being
    # the less certain signal, an undecided case falls back to exited rather than
    # claiming disk_full.
    def self.disk_full?(stderr)
      return false if stderr.nil? || stderr.empty?

      DISK_FULL_PATTERNS.any? { |pattern| stderr.match?(pattern) }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
