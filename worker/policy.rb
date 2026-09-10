# frozen_string_literal: true

require "yaml"
require "protocol/constants"
require "worker/errors"

module Worker
  # ワーカー側の正。VPS から来た値は必ずここで再評価する。
  # 超えていたら拒否ではなく切り詰め、実際に適用した値を applied_limits として返す。
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

    DEFAULT_RUNTIME_DIR = "/run/mcp-sandbox-app"

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
      # docker の -v は相対パスを受け付けないので、ここで絶対パスにしておく
      @runtime_dir = ::File.expand_path(runtime_dir || DEFAULT_RUNTIME_DIR)
    end

    # systemd の LoadCredential= で渡された場合はそちらを優先する。
    # 環境変数にトークンを置かないので、/proc/PID/environ にも systemctl show にも出ない。
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

    # VPS から来た要求値を上限として解釈し、自分の設定を超えていたら切り詰める
    def clamp(requested)
      {
        memory_mb: clamp_value(requested[:memory_mb], "max_memory_mb"),
        cpus: clamp_value(requested[:cpus], "max_cpus"),
        pids: clamp_value(requested[:pids], "max_pids"),
        timeout_s: clamp_value(requested[:timeout_s], "max_timeout_s"),
        tmpfs_mb: clamp_value(requested[:tmpfs_mb], "max_tmpfs_mb")
      }
    end

    # 切り詰められない検証。ここに引っかかったら policy_rejected で返す。
    # 展開する側ではなく、書き出す側で弾く。
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

    def clamp_value(requested, key)
      max = limits.fetch(key)
      return max if requested.nil?

      [ requested, max ].min
    end
  end
end
