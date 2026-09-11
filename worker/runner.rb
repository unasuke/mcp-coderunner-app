# frozen_string_literal: true

require "fileutils"
require "json"
require "protocol/constants"
require "protocol/job_result"
require "protocol/resource_profile"
require "worker/builder"
require "worker/cgroup_stats"
require "worker/docker"
require "worker/errors"
require "worker/supervisor"

module Worker
  # ジョブ 1 件を最後まで面倒を見る。build → run → 統計の採取 → 片付け。
  #
  # 実行コンテナは常に --network none。ネットワークが要るのは build フェーズだけ。
  class Runner
    TRUNCATION_MARKER = "\n...[truncated]...\n"

    def initialize(policy:, logger: nil, builder: nil)
      @policy = policy
      @logger = logger
      @builder = builder || Builder.new(policy:, logger:)
    end

    def call(payload, cancelled: nil)
      started = monotonic
      applied = @policy.clamp(payload.limits)

      validate_identifiers!(payload)
      @policy.validate_context!(payload.blueprint.dockerfile, payload.blueprint.files)
      tag = @builder.ensure_image!(
        digest: payload.blueprint.digest,
        dockerfile: payload.blueprint.dockerfile,
        files: payload.blueprint.files
      )

      execute(payload, applied:, tag:, cancelled:, started:)
    rescue PolicyRejected => e
      failure("policy_rejected", e, applied, started)
    rescue BuildFailed => e
      failure("image_build_failed", e, applied, started)
    rescue Error, SystemCallError, JSON::ParserError => e
      failure("worker_error", e, applied, started)
    rescue StandardError => e
      # ここが最後の砦。ワーカーのバグで例外が漏れると、結果が返らずジョブが
      # 宙吊りになり、リースが失効するまで誰も気づけない
      failure("worker_error", e, applied, started)
    end

    private

    def execute(payload, applied:, tag:, cancelled:, started:)
      container = container_name(payload)
      workdir = prepare_workdir(payload)

      begin
        Docker.run!("run", *run_args(payload, applied:, tag:, workdir:, container:))
        stats = start_stats(container)
        supervisor = Supervisor.new(container:, timeout_s: applied.fetch(:timeout_s), cancelled:)
        supervisor.wait
        stats&.stop

        state = container_state(container)
        stdout, stderr, truncated = collect_logs(container)

        Protocol::JobResult.new(
          termination_reason: reason_for(state:, supervisor:, stats:, stderr:),
          exit_code: state&.fetch("ExitCode", nil),
          stdout:, stderr:, truncated:,
          duration_ms: elapsed_ms(started),
          cpu_time_ms: stats&.cpu_time_ms,
          max_rss_bytes: stats&.max_rss_bytes,
          image_digest: image_digest(tag),
          applied_limits: applied
        )
      ensure
        Docker.run("rm", "--force", container)
        FileUtils.remove_entry(job_dir(payload), true)
      end
    end

    public

    # --rm は付けない。終了と同時にコンテナが消えると State.OOMKilled を読めない。
    # 引数列そのものが検証の対象になるので public にしている。
    def run_args(payload, applied:, tag:, workdir:, container:)
      memory = "#{applied.fetch(:memory_mb)}m"
      args = [
        "--detach",
        "--name", container,
        "--label", "#{Protocol::Constants::CONTAINER_LABEL}=#{payload.job_id}",
        "--network", "none",
        # 承認済み Blueprint 上の script はレビューされない。出力し続けるだけで
        # ホストのディスクを埋められるので、docker 側でも上限を持つ
        "--log-driver", "json-file",
        "--log-opt", "max-size=#{log_max_size}",
        "--log-opt", "max-file=2",
        "--memory", memory,
        "--memory-swap", memory,
        "--cpus", applied.fetch(:cpus).to_s,
        "--pids-limit", applied.fetch(:pids).to_s,
        "--read-only",
        "--tmpfs", "/tmp:rw,size=#{applied.fetch(:tmpfs_mb)}m,mode=1777",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--ulimit", "core=0",
        "--volume", "#{workdir}:/work:ro"
      ]

      # bench は cpuset でピン留めして他のジョブと排他にする
      if Protocol::ResourceProfile.exist?(payload.profile) && Protocol::ResourceProfile.exclusive?(payload.profile)
        args += [ "--cpuset-cpus", "0-#{applied.fetch(:cpus) - 1}" ]
      end

      args + [ tag ] + Array(payload.entrypoint)
    end

    private

    # docker の max-size は k / m / g の接尾辞しか受け付けない
    def log_max_size
      kilobytes = (@policy.max_output_bytes / 1024.0).ceil
      "#{[ kilobytes, 1 ].max}k"
    end

    def prepare_workdir(payload)
      workdir = File.join(job_dir(payload), "work")
      FileUtils.mkdir_p(workdir)
      File.write(File.join(workdir, File.basename(Protocol::Constants::SCRIPT_PATH)), payload.script)
      workdir
    end

    # VPS から来た識別子をそのままパスとコンテナ名に使うので、形を確かめてから使う。
    # ワーカーは VPS を全面的には信用しない。
    def validate_identifiers!(payload)
      [ payload.job_id, payload.lease_id ].each do |id|
        raise PolicyRejected, "invalid identifier: #{id.inspect}" unless id.to_s.match?(/\A[0-9]+\z/)
      end
    end

    def job_dir(payload)
      File.join(@policy.runtime_dir, payload.job_id.to_s)
    end

    def container_name(payload)
      "mcp-coderunner-app-#{payload.job_id}-#{payload.lease_id}"
    end

    def start_stats(container)
      pid = container_state(container)&.fetch("Pid", nil)
      return nil if pid.nil? || pid.zero?

      CgroupStats.new(pid).start
    end

    def container_state(container)
      Docker.inspect_json(container)&.fetch("State", nil)
    end

    # docker のバージョンによって sha256: が付いたり付かなかったりする。
    # DB に入る形を揃えたいので、ここで正規化しておく。
    def image_digest(tag)
      result = Docker.run("image", "inspect", "--format", "{{.Id}}", tag)
      return nil unless result.success?

      id = result.stdout.strip
      return nil if id.empty?

      id.start_with?("sha256:") ? id : "sha256:#{id}"
    end

    def reason_for(state:, supervisor:, stats:, stderr:)
      reason = Supervisor.termination_reason(state:, killed_by: supervisor.killed_by, stats:)
      return "disk_full" if reason == "exited" && Supervisor.disk_full?(stderr)

      reason
    end

    def collect_logs(container)
      result = Docker.run("logs", container)
      stdout, stdout_truncated = truncate(result.stdout)
      stderr, stderr_truncated = truncate(result.stderr)
      [ stdout, stderr, stdout_truncated || stderr_truncated ]
    end

    # 先頭と末尾の両方を残す。エラーは末尾に出るが、原因は先頭に出ることが多い。
    def truncate(text)
      text = text.to_s
      limit = @policy.max_output_bytes
      return [ text, false ] if text.bytesize <= limit

      half = (limit - TRUNCATION_MARKER.bytesize) / 2
      head = text.byteslice(0, half)
      tail = text.byteslice(-half, half)
      [ "#{head}#{TRUNCATION_MARKER}#{tail}".scrub, true ]
    end

    def failure(reason, error, applied, started)
      Protocol::JobResult.new(
        termination_reason: reason,
        stderr: "#{error.class}: #{error.message}",
        duration_ms: elapsed_ms(started),
        applied_limits: applied || {}
      )
    end

    def elapsed_ms(started)
      ((monotonic - started) * 1000).round
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
