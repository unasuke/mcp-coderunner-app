# frozen_string_literal: true

require "open3"
require "worker/errors"

module Worker
  # A thin wrapper over the docker CLI, shared by Builder, Runner and Supervisor.
  # It does not speak to the docker API directly, to avoid adding a dependency to
  # what the VM has to carry (this side is written against stdlib alone).
  module Docker
    Result = Data.define(:stdout, :stderr, :status) do
      def success? = status.success?
    end

    def self.run(*args, stdin: nil)
      stdout, stderr, status = Open3.capture3("docker", *args.map(&:to_s), stdin_data: stdin.to_s)
      Result.new(stdout:, stderr:, status:)
    rescue Errno::ENOENT
      raise DockerError, "docker command not found"
    end

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
