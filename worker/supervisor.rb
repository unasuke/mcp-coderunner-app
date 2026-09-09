# frozen_string_literal: true

require "worker/docker"

module Worker
  # 壁時計のタイムアウトと中断を見張り、終了理由を決める。
  #
  # Ruby はシグナルを握り潰せるので docker stop だけでは足りない。
  # SIGTERM を送って猶予を与え、それでも残っていたら kill する。
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

    # コンテナが終わるまで待つ。戻り値は :exited / :timeout / :cancelled
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

    # 判定の順序が意味を持つ。supervisor が殺したことを最優先にする。
    # タイムアウトで SIGKILL した直後にメモリ圧が出ていると、OOM と誤って記録されうる。
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

    # cgroup の経路に乗らないので stderr からの推定になる。
    # 確度が落ちるぶん、判定できなければ exited に倒して無理に disk_full を名乗らない。
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
