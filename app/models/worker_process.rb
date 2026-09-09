# 起動ごとの実体。短命。
# 生死の判定は last_heartbeat_at の古さだけで行い、行の存在を生存の証拠にしない。
class WorkerProcess < ApplicationRecord
  scope :alive, ->(now = Time.current) {
    where(stopped_at: nil).where(last_heartbeat_at: (now - Protocol::Constants::HEARTBEAT_EXPIRY)..)
  }
  scope :stale, ->(now = Time.current) {
    where(stopped_at: nil).where(last_heartbeat_at: ...(now - Protocol::Constants::HEARTBEAT_EXPIRY))
  }

  validates :instance_id, presence: true, uniqueness: true
  validates :commit_hash, :protocol_version, :capacity, presence: true

  def leases
    Lease.active.held_by(instance_id)
  end

  # busy はワーカーに申告させない。保持している未解放のリースの本数を数える
  def busy
    leases.count
  end

  def alive?(now = Time.current)
    stopped_at.nil? && last_heartbeat_at > now - Protocol::Constants::HEARTBEAT_EXPIRY
  end

  def beat!
    update!(last_heartbeat_at: Time.current)
  end

  def stop!
    update!(stopped_at: Time.current)
  end
end
