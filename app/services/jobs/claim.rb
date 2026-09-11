module Jobs
  # Takes one queued job, writes the leases row, and moves the state to leased,
  # all in one transaction. SQLite serializes writes, so no further lock is needed.
  class Claim
    Claimed = Data.define(:job, :lease, :token)

    def self.call(instance_id:)
      Job.transaction do
        job = next_claimable
        next nil unless job

        lease, token = Lease.issue!(job:, instance_id:)
        job.update!(state: :leased)
        Claimed.new(job:, lease:, token:)
      end
    end

    # bench is exclusive, and both sides hold that (so a drifted VPS still cannot
    # get two running at once).
    #
    #   - while a bench job runs, hand out nothing
    #   - while any other job runs, hand out no bench
    #
    # A ruined measurement looks like a fine result, so this is kept strictly serial.
    def self.next_claimable
      return nil if exclusive_running?

      scope = Job.claimable.where(cancel_requested_at: nil)
      scope = scope.where.not(profile: exclusive_profiles) if running?
      scope.first
    end

    def self.running?
      Job.where(state: [ :leased, :running ]).exists?
    end

    def self.exclusive_profiles
      Protocol::ResourceProfile::NAMES.select { |name| Protocol::ResourceProfile.exclusive?(name) }
    end

    def self.exclusive_running?
      Job.where(state: [ :leased, :running ], profile: exclusive_profiles).exists?
    end
  end
end
