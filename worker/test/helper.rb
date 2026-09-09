# frozen_string_literal: true

# ワーカーのテストは Rails を読まない。stdlib の minitest だけで走らせる。
#   ruby -Ilib -I. worker/test/policy_test.rb

require "minitest/autorun"
require "tmpdir"
require "protocol/blueprint_digest"
require "protocol/job_payload"
require "worker/policy"

module WorkerTestHelper
  def build_policy(**overrides)
    Worker::Policy.new(
      worker_id: "test-worker",
      endpoint: "https://mcprb.invalid",
      limits: overrides.delete(:limits),
      runtime_dir: overrides.delete(:runtime_dir),
      **overrides
    )
  end

  def build_payload(profile: "default", entrypoint: nil, files: [], limits: nil,
                    dockerfile: "FROM ruby:3.4-slim\n", script: "puts 1\n", digest: nil)
    Protocol::JobPayload.from_h({
      "job_id" => 1042,
      "lease_id" => 88,
      "lease_token" => "token",
      "lease_expires_at" => "2026-09-09T12:36:56Z",
      "blueprint" => {
        "digest" => digest || Protocol::BlueprintDigest.compute(dockerfile:, files:),
        "dockerfile" => dockerfile,
        "files" => files
      },
      "script" => script,
      "profile" => profile,
      "entrypoint" => entrypoint,
      "limits" => limits || { "memory_mb" => 2048, "cpus" => 2, "pids" => 512, "timeout_s" => 60, "tmpfs_mb" => 512 }
    }.compact)
  end
end
