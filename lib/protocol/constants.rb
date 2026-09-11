# frozen_string_literal: true

module Protocol
  # Values both the Rails side and the worker side have to agree on. Changing
  # one side alone breaks the pair, so they are written in exactly one place.
  module Constants
    # Bumped only when the wire format of lease / result changes
    PROTOCOL_VERSION = 1

    # The long-polling window of /lease, in seconds. The worker's read_timeout must exceed it
    LEASE_WAIT = 25

    # Interval of the worker heartbeat and the job heartbeat, in seconds
    HEARTBEAT_INTERVAL = 30

    # How often /lease looks for a queued job while long-polling, in seconds.
    # Shortening it gets a job moving sooner after it is enqueued, at the cost
    # of more empty queries and more writes to last_heartbeat_at
    LEASE_POLL_INTERVAL = 3

    # An instance silent for this long is considered dead, in seconds. Four times the interval
    HEARTBEAT_EXPIRY = 120

    # How far ahead lease_expires_at is set, in seconds. Pushed out on every job heartbeat
    LEASE_TTL = 120

    # Once this many leases exist for a job, it is not retried again
    MAX_ATTEMPTS = 2

    # Where the script is placed inside the job container
    SCRIPT_PATH = "/work/script.rb"

    DEFAULT_ENTRYPOINT = [ "ruby", SCRIPT_PATH ].freeze

    # The mark that lets orphaned containers be swept up
    CONTAINER_LABEL = "mcp-coderunner-app.job"

    # The repository for built images. The digest is used verbatim as the tag
    IMAGE_REPO = "mcp-coderunner-app/bp"

    # The reasons /deregister accepts
    DEREGISTER_REASONS = %w[ shutdown update drained ].freeze
  end
end
