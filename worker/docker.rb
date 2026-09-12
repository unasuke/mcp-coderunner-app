# frozen_string_literal: true

require "open3"
require "worker/errors"

module Worker
  # A thin wrapper over the docker CLI, shared by Builder, Runner and Supervisor.
  # It does not speak to the docker API directly, to avoid adding a dependency to
  # what the VM has to carry (this side is written against stdlib alone).
  module Docker
    COMMAND = "docker"

    # How often a cancellable command is asked whether it should still be running,
    # and how long it is given after SIGTERM before SIGKILL
    CANCEL_POLL_INTERVAL = 0.2
    CANCEL_GRACE = 5

    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.success?
    end

    # Pass `cancelled` for a command that has to be interruptible. capture3 waits
    # for the command whatever happens, which is right for everything short and
    # wrong for a build: those run for minutes, and a worker told to stop -- by
    # SIGTERM, or by an admin cancelling the job -- would sit in the build until the
    # shutdown grace ran out and then leave it running.
    def self.run(*args, stdin: nil, cancelled: nil, command: COMMAND)
      argv = [ command, *args.map(&:to_s) ]

      cancelled ? interruptible(argv, stdin, cancelled) : capture(argv, stdin)
    rescue Errno::ENOENT
      raise DockerError, "#{command} command not found"
    end

    def self.capture(argv, stdin)
      stdout, stderr, status = Open3.capture3(*argv, stdin_data: stdin.to_s)
      Result.new(stdout:, stderr:, status:)
    end

    def self.interruptible(argv, stdin, cancelled)
      Open3.popen3(*argv) do |input, out, err, waiter|
        input.write(stdin.to_s)
        input.close

        # Read both pipes while waiting, or a chatty build fills one and blocks
        readers = { stdout: Thread.new { out.read }, stderr: Thread.new { err.read } }
        wait_or_terminate(waiter, cancelled)

        Result.new(stdout: readers[:stdout].value, stderr: readers[:stderr].value,
          status: waiter.value)
      end
    end

    def self.wait_or_terminate(waiter, cancelled)
      killed_at = nil

      until waiter.join(CANCEL_POLL_INTERVAL)
        next unless cancelled.call

        if killed_at.nil?
          Process.kill("TERM", waiter.pid)
          killed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) - killed_at >= CANCEL_GRACE
          Process.kill("KILL", waiter.pid)
          killed_at = Float::INFINITY
        end
      end
    rescue Errno::ESRCH
      nil # it exited between the check and the signal
    end
    private_class_method :capture, :interruptible, :wait_or_terminate

    def self.run!(*args, stdin: nil)
      result = run(*args, stdin:)
      raise DockerError, "docker #{args.first} failed: #{result.stderr.strip}" unless result.success?
      result
    end

    def self.inspect_json(name)
      result = run("inspect", name)
      return nil unless result.success?

      JSON.parse(result.stdout).first
    end

    def self.image_exist?(tag)
      run("image", "inspect", tag).success?
    end
  end
end
