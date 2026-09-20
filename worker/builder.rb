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

    # How long a stopped job container is left alone before prune takes it. Longer
    # than any job may run, so a container still being read from is never taken
    CONTAINER_GRACE_HOURS = 1

    def initialize(policy:, logger: nil)
      @policy = policy
      @logger = logger
    end

    def image_tag(digest)
      "#{Protocol::Constants::IMAGE_REPO}:#{digest}"
    end

    def ensure_image!(digest:, dockerfile:, files:, cancelled: nil)
      tag = image_tag(digest)
      return tag if Docker.image_exist?(tag)

      build!(tag:, dockerfile:, files:, cancelled:)
      tag
    end

    # cancelled is carried down to the build itself. It is the long part of a job,
    # and a worker that has been told to stop cannot wait it out
    def build!(tag:, dockerfile:, files:, cancelled: nil)
      Dir.mktmpdir("mcp-coderunner-app-build") do |dir|
        write_context(dir, dockerfile, files)

        result = Docker.run("build", "--tag", tag, "--file", File.join(dir, "Dockerfile"), dir,
          cancelled:)
        unless result.success?
          raise BuildFailed, tail(result.stderr)
        end

        result
      end
    end

    # Kept in hand with cache_ttl_days and max_images. Worth having if you pull
    # ruby-head nightly.
    #
    # The tagged images are the smaller half of what building leaves on the disk.
    # A rebuild of the same tag leaves the image it replaced dangling, where the
    # tag listing cannot see it; BuildKit keeps a cache of its own; and a worker
    # that was killed rather than stopped leaves its job containers behind. The
    # daemon is rootless and this account's alone, so nothing else on the VM is
    # holding any of it.
    def prune!(now: Time.now)
      images = prunable_images(now:)
      images.each { |image| Docker.run("image", "rm", "--force", image.fetch(:id)) }

      # Only stopped containers are collected, and only ones old enough that no
      # runner can still be reading their output -- a job lives max_timeout_s
      containers = Docker.run("container", "prune", "--force",
        "--filter", "label=#{Protocol::Constants::CONTAINER_LABEL}",
        "--filter", "until=#{CONTAINER_GRACE_HOURS}h")
      dangling = Docker.run("image", "prune", "--force")
      build_cache = Docker.run("builder", "prune", "--force", "--all",
        "--filter", "until=#{@policy.build_cache_ttl_hours}h")

      {
        images: images.size,
        containers: reclaimed(containers),
        dangling: reclaimed(dangling),
        build_cache: reclaimed(build_cache)
      }
    end

    # Past cache_ttl_days, plus whatever is over max_images counting from the oldest
    def prunable_images(now:)
      images = list_images
      expired = images.select { |image| image.fetch(:created_at) < now - (@policy.cache_ttl_days * 86_400) }
      surplus = images.sort_by { |image| image.fetch(:created_at) }.first([ images.size - @policy.max_images, 0 ].max)

      expired | surplus
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

    # docker ends a prune with "Total reclaimed space: 1.2GB". Worth carrying into
    # the log, because the reason for pruning this often is the disk
    def reclaimed(result)
      result.stdout[/Total reclaimed space:\s*(\S+)/, 1] || "0B"
    end

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
