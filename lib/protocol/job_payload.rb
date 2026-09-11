# frozen_string_literal: true

require "time"
require "protocol/constants"

module Protocol
  # One job as returned by /lease, and what the worker runs from.
  # files always arrive inline; there is no fetch-from-a-URL path.
  class JobPayload
    Invalid = Class.new(StandardError)

    ContextFile = Data.define(:path, :content, :executable)
    Blueprint = Data.define(:digest, :dockerfile, :files)

    attr_reader :job_id, :lease_id, :lease_token, :lease_expires_at, :blueprint, :script, :profile,
      :entrypoint, :limits

    def self.from_h(hash)
      new(
        job_id: fetch!(hash, "job_id"),
        lease_id: fetch!(hash, "lease_id"),
        lease_token: fetch!(hash, "lease_token"),
        lease_expires_at: Time.iso8601(fetch!(hash, "lease_expires_at")),
        blueprint: build_blueprint(fetch!(hash, "blueprint")),
        script: fetch!(hash, "script"),
        profile: fetch!(hash, "profile"),
        entrypoint: hash["entrypoint"] || Constants::DEFAULT_ENTRYPOINT,
        limits: symbolize(fetch!(hash, "limits"))
      )
    rescue ArgumentError => e
      # Time.iso8601 gave up. Callers have no reason to tell this apart from the other ways it can be malformed
      raise Invalid, "invalid lease payload: #{e.message}"
    end

    def self.fetch!(hash, key)
      hash.fetch(key) { raise Invalid, "missing key: #{key}" }
    end

    def self.build_blueprint(hash)
      Blueprint.new(
        digest: fetch!(hash, "digest"),
        dockerfile: fetch!(hash, "dockerfile"),
        files: Array(hash["files"]).map { |file|
          ContextFile.new(
            path: fetch!(file, "path"),
            content: fetch!(file, "content"),
            executable: !!file["executable"]
          )
        }
      )
    end

    def self.symbolize(hash)
      hash.to_h { |key, value| [ key.to_sym, value ] }
    end
    private_class_method :build_blueprint, :symbolize

    def initialize(job_id:, lease_id:, lease_token:, lease_expires_at:, blueprint:, script:, profile:,
                   entrypoint:, limits:)
      @job_id = job_id
      @lease_id = lease_id
      @lease_token = lease_token
      @lease_expires_at = lease_expires_at
      @blueprint = blueprint
      @script = script
      @profile = profile
      @entrypoint = entrypoint
      @limits = limits
    end

    def image_tag
      "#{Constants::IMAGE_REPO}:#{blueprint.digest}"
    end
  end
end
