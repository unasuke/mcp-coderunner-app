# frozen_string_literal: true

require_relative "helper"
require "worker/builder"

class BuilderTest < Minitest::Test
  include WorkerTestHelper

  # Docker::Result asks its status whether it succeeded, and nothing here shells out
  class FakeStatus
    def success? = true
  end

  def setup
    @builder = Worker::Builder.new(policy: build_policy)
  end

  def test_writes_the_context_with_the_right_modes
    Dir.mktmpdir do |dir|
      files = [
        Protocol::JobPayload::ContextFile.new(path: "Gemfile", content: "source 'x'", executable: false),
        Protocol::JobPayload::ContextFile.new(path: "bin/run", content: "#!/bin/sh", executable: true)
      ]
      @builder.send(:write_context, dir, "FROM ruby\n", files)

      assert_equal "FROM ruby\n", File.read(File.join(dir, "Dockerfile"))
      assert_equal 0o644, File.stat(File.join(dir, "Gemfile")).mode & 0o777
      assert_equal 0o755, File.stat(File.join(dir, "bin/run")).mode & 0o777
    end
  end

  # Refused where the files are written, not where they are unpacked. The build phase runs as root
  def test_refuses_to_write_outside_the_context
    Dir.mktmpdir do |dir|
      files = [ Protocol::JobPayload::ContextFile.new(path: "../escaped", content: "x", executable: false) ]

      assert_raises(Worker::PolicyRejected) { @builder.send(:write_context, dir, "FROM ruby\n", files) }
    end
  end

  # Age alone. The fresh one stays even though the build cache around it goes
  def test_prune_removes_the_images_past_the_ttl
    now = Time.now
    calls = prune_with(images: [ [ "fresh", now - 3600 ], [ "expired", now - (5 * 86_400) ] ],
      build: { "cache_ttl_days" => 3, "max_images" => 10 }, now:)

    assert_includes calls, [ "image", "rm", "--force", "expired" ]
    refute_includes calls, [ "image", "rm", "--force", "fresh" ]
  end

  # Over max_images the oldest go, whatever their age
  def test_prune_removes_the_images_over_the_ceiling
    now = Time.now
    calls = prune_with(images: [ [ "newest", now - 60 ], [ "middle", now - 120 ], [ "oldest", now - 180 ] ],
      build: { "cache_ttl_days" => 3, "max_images" => 2 }, now:)

    assert_includes calls, [ "image", "rm", "--force", "oldest" ]
    refute_includes calls, [ "image", "rm", "--force", "middle" ]
  end

  # What the tag listing cannot see is the larger half of the disk, so prune takes
  # the dangling images, the containers a killed worker left and BuildKit's cache
  def test_prune_takes_what_the_tags_do_not_cover
    calls = prune_with(images: [], build: { "build_cache_ttl_hours" => 6 })

    assert_includes calls, [ "image", "prune", "--force" ]
    assert_includes calls, [ "container", "prune", "--force",
      "--filter", "label=#{Protocol::Constants::CONTAINER_LABEL}",
      "--filter", "until=#{Worker::Builder::CONTAINER_GRACE_HOURS}h" ]
    assert_includes calls, [ "builder", "prune", "--force", "--all", "--filter", "until=6h" ]
  end

  def test_prune_reports_what_came_back
    prune_with(images: [ [ "expired", Time.now - (5 * 86_400) ] ])

    assert_equal 1, @summary.fetch(:images)
    assert_equal "1.2GB", @summary.fetch(:build_cache)
  end

  private

  # Stands in for the whole docker CLI: the images listing comes back in the shape
  # list_images parses, everything else answers the way a prune does. Returns the
  # commands that were run, and leaves the summary in @summary
  def prune_with(images:, build: nil, now: Time.now)
    @calls = []
    fake = lambda do |*args, **|
      @calls << args
      stdout = if args.first == "images"
        images.map { |id, created_at| "#{id}\t#{created_at.strftime("%Y-%m-%d %H:%M:%S %z")}" }.join("\n")
      else
        "Total reclaimed space: 1.2GB\n"
      end

      Worker::Docker::Result.new(stdout:, stderr: "", status: FakeStatus.new)
    end

    builder = Worker::Builder.new(policy: build_policy(build:))
    stub_docker(fake) { @summary = builder.prune!(now:) }
    @calls
  end

  # minitest 6 dropped minitest/mock, and the worker's tests carry no gems of
  # their own. Swapping the singleton method back on the way out does the same job
  def stub_docker(fake)
    original = Worker::Docker.method(:run)
    Worker::Docker.define_singleton_method(:run) { |*args, **kwargs| fake.call(*args, **kwargs) }
    yield
  ensure
    Worker::Docker.define_singleton_method(:run, original)
  end
end
