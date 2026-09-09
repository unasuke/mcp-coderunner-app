# frozen_string_literal: true

module Protocol
  # POST /jobs/:id/result のペイロード。そのまま job_results の 1 行になる。
  #
  # termination_reason を構造化して返すのは、原因が分からないと同じジョブを
  # 条件を変えずに投げ直すことになるため。
  class JobResult
    Invalid = Class.new(StandardError)

    REASONS = [
      "exited",             # 正常終了（exit_code を見る）
      "timeout",            # 壁時計超過。SIGKILL された
      "oom_killed",         # State.OOMKilled か cgroup の oom_kill
      "pids_exceeded",      # pids.events の max が立った
      "disk_full",          # stderr からの推定
      "image_build_failed",
      "policy_rejected",    # ワーカーの検証 / clamp に弾かれた
      "worker_error",       # docker 自体の失敗、ワーカーのバグ
      "lease_expired",      # ワーカーが応答しなくなった
      "cancelled"           # UI から中断された
    ].freeze

    # コンテナが走っていないので実行系の統計を持たない終了理由
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
