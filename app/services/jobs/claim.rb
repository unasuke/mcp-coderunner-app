module Jobs
  # queued のジョブを 1 件掴んで leases の行を作り、state を leased にするところまでを
  # 1 トランザクションで行う。SQLite は書き込みが直列なので、追加のロックは要らない。
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

    # bench は排他。サーバーとワーカーの両方で持つ（VPS の状態がずれても 2 本同時に走らせない）。
    #
    #   - bench が走っているあいだは何も渡さない
    #   - ほかのジョブが走っているあいだは bench を渡さない
    #
    # 測定値が壊れても結果を見ただけでは分からないので、ここは厳しく直列にする。
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
