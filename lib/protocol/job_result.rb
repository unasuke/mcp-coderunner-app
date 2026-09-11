# frozen_string_literal: true

module Protocol
  # The payload of POST /jobs/:id/result. It becomes one row of job_results as-is.
  #
  # termination_reason is structured rather than prose because without knowing why
  # a job ended, the only move left is to submit the same job again unchanged.
  class JobResult
    Invalid = Class.new(StandardError)

    REASONS = [
      "exited",             # ran to completion (read exit_code)
      "timeout",            # went past the wall clock and was SIGKILLed
      "oom_killed",         # State.OOMKilled, or oom_kill from the cgroup
      "pids_exceeded",      # the max counter in pids.events moved
      "disk_full",          # inferred from stderr
      "image_build_failed",
      "policy_rejected",    # turned away by the worker's own validation or clamp
      "worker_error",       # docker itself failed, or the worker has a bug
      "lease_expired",      # the worker stopped answering
      "cancelled"           # stopped from the UI
    ].freeze

    # Reasons that carry no runtime statistics, because no container ever ran
    REASONS_WITHOUT_CONTAINER = %w[ image_build_failed policy_rejected worker_error lease_expired ].freeze

    attr_reader :termination_reason, :exit_code, :stdout, :stderr, :truncated,
      :duration_ms, :cpu_time_ms, :max_rss_bytes, :image_digest, :applied_limits

    def initialize(termination_reason:, exit_code: nil, stdout: "", stderr: "", truncated: false,
                   duration_ms: nil, cpu_time_ms: nil, max_rss_bytes: nil, image_digest: nil,
                   applied_limits: {})
      unless REASONS.include?(termination_reason)
        raise Invalid, "unknown termination_reason: #{termination_reason.inspect}"
      end

      @termination_reason = termination_reason
      @exit_code = exit_code
      @stdout = stdout
      @stderr = stderr
      @truncated = truncated
      @duration_ms = duration_ms
      @cpu_time_ms = cpu_time_ms
      @max_rss_bytes = max_rss_bytes
      @image_digest = image_digest
      @applied_limits = applied_limits
    end

    def to_h
      {
        "termination_reason" => termination_reason,
        "exit_code" => exit_code,
        "stdout" => stdout,
        "stderr" => stderr,
        "truncated" => truncated,
        "duration_ms" => duration_ms,
        "cpu_time_ms" => cpu_time_ms,
        "max_rss_bytes" => max_rss_bytes,
        "image_digest" => image_digest,
        "applied_limits" => applied_limits
      }
    end
  end
end
