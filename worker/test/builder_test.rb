# frozen_string_literal: true

require_relative "helper"
require "worker/builder"

class BuilderTest < Minitest::Test
  include WorkerTestHelper

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
end
