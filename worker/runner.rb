# frozen_string_literal: true

require "fileutils"
require "json"
require "protocol/blueprint_digest"
require "protocol/constants"
require "protocol/job_result"
require "protocol/resource_profile"
require "worker/builder"
require "worker/cgroup_stats"
require "worker/docker"
require "worker/errors"
require "worker/supervisor"

module Worker
  # Sees one job all the way through: build, run, collect statistics, clean up.
  #
  # A job container always runs with --network none. The build phase is the only
  # part that needs the network at all.
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
      validate_digest!(payload)
      @policy.validate_context!(payload.blueprint.dockerfile, payload.blueprint.files)
      tag = @builder.ensure_image!(
        digest: payload.blueprint.digest,
        dockerfile: payload.blueprint.dockerfile,
        files: payload.blueprint.files,
        cancelled:
      )

      execute(payload, applied:, tag:, cancelled:, started:)
    rescue PolicyRejected => e
      failure("policy_rejected", e, applied, started)
    rescue BuildFailed => e
      # A build cut short on the way out is not a broken Dockerfile
      cancelled&.call ? cancelled_result(applied, started) : failure("image_build_failed", e, applied, started)
    rescue Error, SystemCallError, JSON::ParserError => e
      failure("worker_error", e, applied, started)
    rescue StandardError => e
      # The last line of defense. If a bug in the worker lets an exception out,
      # no result is ever sent, the job hangs, and nobody notices until the lease
      # expires
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
        Docker.run("rm", "--force", "--volumes", container)
        FileUtils.remove_entry(job_dir(payload), true)
      end
    end

    public

    # No --rm. A container that disappears the moment it exits takes
    # State.OOMKilled with it. Public because the argument list itself is what
    # the tests check.
    def run_args(payload, applied:, tag:, workdir:, container:)
      memory = "#{applied.fetch(:memory_mb)}m"
      args = [
        "--detach",
        "--name", container,
        "--label", "#{Protocol::Constants::CONTAINER_LABEL}=#{payload.job_id}",
        "--network", "none",
        # A script running on an approved Blueprint is not itself reviewed. Left
        # printing, it can fill the host's disk on its own, so docker holds a
        # ceiling of its own too
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
        # Fail on a tag that is not already local, rather than pulling something
        # from the Hub that happens to share the name
        "--pull", "never",
        "--volume", "#{workdir}:/work:ro"
      ]

      # No --cpuset-cpus for bench. What keeps an exclusive job alone is the
      # serialization on both sides -- Jobs::Claim hands out nothing beside it, and
      # JobRegistry waits for the rest to drain. Pinning was only ever about holding
      # the measurement steady, and a rootless daemon does not get the cpuset
      # controller delegated: docker takes the flag, warns that it discarded it, and
      # the warning lands in the stderr of the very job being measured.
      args + [ tag ] + Array(payload.entrypoint)
    end

    private

    # docker's max-size only takes a k / m / g suffix
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

    # Identifiers from the VPS go straight into a path and a container name, so
    # check their shape before using them. The worker does not extend the VPS full
    # trust.
    def validate_identifiers!(payload)
      [ payload.job_id, payload.lease_id ].each do |id|
        raise PolicyRejected, "invalid identifier: #{id.inspect}" unless id.to_s.match?(/\A[0-9]+\z/)
      end

      unless payload.blueprint.digest.to_s.match?(/\A[0-9a-f]{64}\z/)
        raise PolicyRejected, "invalid digest: #{payload.blueprint.digest.inspect}"
      end
    end

    # The digest is the unit approval is granted in, so recompute it from the
    # content that arrived and compare. A mismatch means something is claiming the
    # tag of a different, approved image
    def validate_digest!(payload)
      recomputed = Protocol::BlueprintDigest.compute(
        dockerfile: payload.blueprint.dockerfile,
        files: payload.blueprint.files.map { |file|
          { path: file.path, content: file.content, executable: file.executable }
        }
      )
      return if recomputed == payload.blueprint.digest

      raise PolicyRejected, "digest does not match the context: #{payload.blueprint.digest} != #{recomputed}"
    end

    # One directory per lease, so a re-lease does not collide with the mount left
    # by the previous attempt
    def job_dir(payload)
      File.join(@policy.runtime_dir, "#{payload.job_id}-#{payload.lease_id}")
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

    # Depending on the docker version, the sha256: prefix is there or it is not.
    # Normalize here so one shape reaches the database.
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

    # Keep both ends. The error shows up at the tail, but what caused it is
    # usually near the head.
    def truncate(text)
      text = text.to_s
      limit = @policy.max_output_bytes
      return [ text, false ] if text.bytesize <= limit

      half = (limit - TRUNCATION_MARKER.bytesize) / 2
      head = text.byteslice(0, half)
      tail = text.byteslice(-half, half)
      [ "#{head}#{TRUNCATION_MARKER}#{tail}".scrub, true ]
    end

    def cancelled_result(applied, started)
      Protocol::JobResult.new(
        termination_reason: "cancelled",
        duration_ms: elapsed_ms(started),
        applied_limits: applied || {}
      )
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
