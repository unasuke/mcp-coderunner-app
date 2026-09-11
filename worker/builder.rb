# frozen_string_literal: true

require "fileutils"
require "time"
require "tmpdir"
require "protocol/constants"
require "worker/docker"
require "worker/errors"

module Worker
  # Builds the image a job runs in, out of a Blueprint. The tag is the digest itself.
  #
  # If an image with that digest is already here, this does nothing -- which is what
  # keeps bundle install from running on every job. BuildKit's layer cache still
  # works the way it always does.
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
      Dir.mktmpdir("mcp-coderunner-app-build") do |dir|
        write_context(dir, dockerfile, files)

        result = Docker.run("build", "--tag", tag, "--file", File.join(dir, "Dockerfile"), dir)
        unless result.success?
          raise BuildFailed, tail(result.stderr)
        end

        result
      end
    end

    # Kept in hand with cache_ttl_days and max_images. Worth having if you pull
    # ruby-head nightly.
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

    # blueprint_files carry no mode. The only distinction worth having is whether a
    # file is executable, and allowing an arbitrary mode would let setuid / setgid
    # through as well. The build phase runs as root.
    def write_context(dir, dockerfile, files)
      File.write(File.join(dir, "Dockerfile"), dockerfile)

      files.each do |file|
        path = resolve_within(dir, file.path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, file.content)
        File.chmod(file.executable ? 0o755 : 0o644, path)
      end
    end

    # Runner already refuses these through Policy, but check again where the write
    # happens. The build phase runs as root, so getting past this one matters.
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
