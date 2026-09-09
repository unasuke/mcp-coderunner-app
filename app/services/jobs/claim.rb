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

    # bench は排他。サーバーとワーカーの両方で持つ（VPS の状態がずれても 2 本同時に走らせない）
    def self.next_claimable
      scope = Job.claimable
      scope = scope.where.not(profile: exclusive_profiles) if exclusive_running?
      scope.first
    end

    def self.exclusive_profiles
      Protocol::ResourceProfile::NAMES.select { |name| Protocol::ResourceProfile.exclusive?(name) }
    end

    def self.exclusive_running?
      Job.where(state: [ :leased, :running ], profile: exclusive_profiles).exists?
    end
  end
end
