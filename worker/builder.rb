# frozen_string_literal: true

require "fileutils"
require "time"
require "tmpdir"
require "protocol/constants"
require "worker/docker"
require "worker/errors"

module Worker
  # Blueprint から実行用のイメージを作る。タグは digest そのもの。
  #
  # 同じ digest のイメージが既にあれば何もしない。これで bundle install が
  # 毎回走る問題は消える。BuildKit のレイヤキャッシュもそのまま効く。
  class Builder
    STDERR_TAIL_BYTES = 8192

    def initialize(policy:, logger: nil)
      @policy = policy
      @logger = logger
    end

    def image_tag(digest)
      "#{Protocol::Constants::IMAGE_REPO}:#{digest}"
    end

    def ensure_image!(digest:, dockerfile:, files:)
      tag = image_tag(digest)
      return tag if Docker.image_exist?(tag)

      build!(tag:, dockerfile:, files:)
      tag
    end

    def build!(tag:, dockerfile:, files:)
      Dir.mktmpdir("mcp-sandbox-app-build") do |dir|
        write_context(dir, dockerfile, files)

        result = Docker.run("build", "--tag", tag, "--file", File.join(dir, "Dockerfile"), dir)
        unless result.success?
          raise BuildFailed, tail(result.stderr)
        end

        result
      end
    end

    # cache_ttl_days と max_images で自前管理する。ruby-head を毎晩引くなら特に必要。
    def prune!(now: Time.now)
      images = list_images
      expired = images.select { |image| image.fetch(:created_at) < now - (@policy.cache_ttl_days * 86_400) }
      surplus = images.sort_by { |image| image.fetch(:created_at) }.first([ images.size - @policy.max_images, 0 ].max)

      (expired | surplus).each do |image|
        Docker.run("image", "rm", "--force", image.fetch(:id))
      end
    end

    def list_images
      result = Docker.run("images", "--filter", "reference=#{Protocol::Constants::IMAGE_REPO}",
        "--format", "{{.ID}}\t{{.CreatedAt}}")
      return [] unless result.success?

      result.stdout.lines.filter_map do |line|
        id, created_at = line.strip.split("\t", 2)
        next if id.nil? || created_at.nil?

        { id:, created_at: Time.parse(created_at) }
      rescue ArgumentError
        nil
      end
    end

    private

    # blueprint_files は mode を持たない。必要な区別は実行可能かどうかだけで、
    # 任意の mode を許すと setuid / setgid まで通る。build フェーズは root で走る。
    def write_context(dir, dockerfile, files)
      File.write(File.join(dir, "Dockerfile"), dockerfile)

      files.each do |file|
        path = resolve_within(dir, file.path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, file.content)
        File.chmod(file.executable ? 0o755 : 0o644, path)
      end
    end

    # Runner が Policy で弾いているが、書き出す側でも確かめる。
    # build フェーズは root で走るので、ここを抜けられると影響が大きい。
    def resolve_within(dir, path)
      base = File.realpath(dir)
      resolved = File.expand_path(path, base)
      unless resolved.start_with?("#{base}/")
        raise PolicyRejected, "path escapes the context: #{path}"
      end

      resolved
    end

    def tail(text)
      return "" if text.nil?

      text.bytesize > STDERR_TAIL_BYTES ? text.byteslice(-STDERR_TAIL_BYTES, STDERR_TAIL_BYTES) : text
    end
  end
end
