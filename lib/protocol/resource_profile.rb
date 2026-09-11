# frozen_string_literal: true

module Protocol
  # Named resource profiles. Callers do not get to name numbers; only the
  # combinations listed here are allowed. Rails uses them to validate submit_job
  # and to fill in the concrete values it sends with a lease; the worker uses
  # them as the input to its own clamp.
  module ResourceProfile
    ALL = {
      "default" => {
        memory_mb: 2048, cpus: 2, pids: 512, timeout_s: 60, tmpfs_mb: 512,
        exclusive: false, requires_approval: false
      },
      "bench" => {
        memory_mb: 4096, cpus: 4, pids: 1024, timeout_s: 300, tmpfs_mb: 1024,
        exclusive: true, requires_approval: true
      }
    }.freeze

    NAMES = ALL.keys.freeze

    DEFAULT = "default"

    # The limits sent with a lease. exclusive and requires_approval are the server's
    # own business, so they stay out of it
    LIMIT_KEYS = %i[ memory_mb cpus pids timeout_s tmpfs_mb ].freeze

    def self.exist?(name)
      ALL.key?(name)
    end

    def self.fetch(name)
      ALL.fetch(name) { raise KeyError, "unknown profile: #{name.inspect}" }
    end

    def self.limits_for(name)
      fetch(name).slice(*LIMIT_KEYS)
    end

    def self.exclusive?(name)
      fetch(name).fetch(:exclusive)
    end

    def self.requires_approval?(name)
      fetch(name).fetch(:requires_approval)
    end
  end
end
