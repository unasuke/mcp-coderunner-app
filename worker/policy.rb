# frozen_string_literal: true

require "yaml"
require "protocol/constants"
require "worker/errors"

module Worker
  # The worker's own source of truth. Anything the VPS asks for is re-evaluated
  # here. Over the line it is trimmed rather than refused, and what was actually
  # applied comes back as applied_limits.
  class Policy
    DEFAULT_LIMITS = {
      "max_memory_mb" => 4096,
      "max_cpus" => 4,
      "max_pids" => 1024,
      "max_timeout_s" => 600,
      "max_tmpfs_mb" => 1024,
      "max_context_bytes" => 1_048_576,
      "max_output_bytes" => 262_144,
      "max_concurrency" => 2
    }.freeze

    DEFAULT_BUILD = {
      "cache_ttl_days" => 14,
      "max_images" => 40
    }.freeze

    # Not under /run. The rootless daemon runs inside rootlesskit, which is started
    # with --copy-up=/run: its /run is a tmpfs of its own, filled in when it started.
    # A directory the worker creates under the host's /run afterwards does not exist
    # over there, and docker answers a bind of a missing path by making an empty
    # directory -- so the container gets an empty /work and the script it was asked
    # to run is simply not there.
    #
    # /var/lib is shared, and this sits under the unit's StateDirectory, which is
    # writable even with ProtectSystem=strict.
    DEFAULT_RUNTIME_DIR = "/var/lib/mcp-coderunner-app/work"

    MAX_PATH_LENGTH = 255

    attr_reader :worker_id, :endpoint, :limits, :build, :runtime_dir

    def self.load(path)
      config = YAML.safe_load_file(path)
      raise Error, "#{path}: expected a mapping" unless config.is_a?(Hash)

      new(
        worker_id: config.fetch("worker_id"),
        endpoint: config.fetch("endpoint"),
        token_file: config["token_file"],
        limits: config["limits"],
        build: config["build"],
        runtime_dir: config["runtime_dir"]
      )
    end

    def initialize(worker_id:, endpoint:, token_file: nil, limits: nil, build: nil, runtime_dir: nil)
      @worker_id = worker_id
      @endpoint = endpoint
      @token_file = token_file
      @limits = DEFAULT_LIMITS.merge(limits || {})
      @build = DEFAULT_BUILD.merge(build || {})
      # docker -v will not take a relative path, so make it absolute here
      @runtime_dir = ::File.expand_path(runtime_dir || DEFAULT_RUNTIME_DIR)
    end

    # A credential handed over by systemd's LoadCredential= wins. The token never
    # goes in the environment, so it shows up in neither /proc/PID/environ nor
    # systemctl show.
    def token
      @token ||= ::File.read(token_path).strip
    end

    def token_path
      credentials_dir = ENV["CREDENTIALS_DIRECTORY"]
      if credentials_dir && ::File.exist?(::File.join(credentials_dir, "api_token"))
        ::File.join(credentials_dir, "api_token")
      elsif @token_file
        @token_file
      else
        raise Error, "no token_file configured and no systemd credential found"
      end
    end

    def max_concurrency = limits.fetch("max_concurrency")
    def max_output_bytes = limits.fetch("max_output_bytes")
    def max_context_bytes = limits.fetch("max_context_bytes")
    def cache_ttl_days = build.fetch("cache_ttl_days")
    def max_images = build.fetch("max_images")

    # Read what the VPS asked for as a ceiling and trim anything above this
    # worker's own. Only the top is trimmed; the bottom is refused instead.
    # Docker reads --pids-limit -1 as "unlimited", so letting a negative through
    # quietly would remove the limit rather than tighten it
    def clamp(requested)
      {
        memory_mb: clamp_integer(requested[:memory_mb], "max_memory_mb"),
        cpus: clamp_number(requested[:cpus], "max_cpus"),
        pids: clamp_integer(requested[:pids], "max_pids"),
        timeout_s: clamp_integer(requested[:timeout_s], "max_timeout_s"),
        tmpfs_mb: clamp_integer(requested[:tmpfs_mb], "max_tmpfs_mb")
      }
    end

    # The validation that cannot be trimmed into shape. Anything caught here comes
    # back as policy_rejected. It is refused where the files get written, not where
    # they get unpacked.
    def validate_context!(dockerfile, files)
      total = dockerfile.to_s.bytesize
      files.each do |file|
        validate_path!(file.path)
        total += file.content.to_s.bytesize
      end

      if total > max_context_bytes
        raise PolicyRejected, "context too large: #{total} bytes (max #{max_context_bytes})"
      end

      true
    end

    def validate_path!(path)
      raise PolicyRejected, "empty path" if path.nil? || path.empty?
      raise PolicyRejected, "path too long: #{path}" if path.length > MAX_PATH_LENGTH
      raise PolicyRejected, "absolute path: #{path}" if path.start_with?("/")
      raise PolicyRejected, "backslash in path: #{path}" if path.include?("\\")
      raise PolicyRejected, "null byte in path" if path.include?("\0")

      segments = path.split("/")
      if segments.any? { |segment| segment == ".." }
        raise PolicyRejected, "path escapes the context: #{path}"
      end

      true
    end

    private

    # Handed to docker as an integer. Anything below 1 is refused
    def clamp_integer(requested, key)
      max = limits.fetch(key)
      return max if requested.nil?

      value = numeric(requested, key).to_i
      raise PolicyRejected, "#{key.sub("max_", "")} must be positive: #{requested.inspect}" unless value.positive?

      [ value, max ].min
    end

    # cpus may be fractional. The profiles are whole numbers, but there is no
    # reason to narrow what the input is allowed to look like
    def clamp_number(requested, key)
      max = limits.fetch(key)
      return max if requested.nil?

      value = numeric(requested, key)
      raise PolicyRejected, "#{key.sub("max_", "")} must be positive: #{requested.inspect}" unless value.positive?

      [ value, max ].min
    end

    def numeric(value, key)
      case value
      when Numeric then value
      when String then Float(value)
      else raise PolicyRejected, "#{key.sub("max_", "")} is not a number: #{value.inspect}"
      end
    rescue ArgumentError, TypeError
      raise PolicyRejected, "#{key.sub("max_", "")} is not a number: #{value.inspect}"
    end
  end
end
