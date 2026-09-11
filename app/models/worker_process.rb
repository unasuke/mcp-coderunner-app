# One run of the process. Short-lived.
# Whether it is alive is decided by the age of last_heartbeat_at alone; the row
# existing is never taken as evidence of life.
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

  # The worker does not get to declare it is busy. Count the leases it holds unreleased
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
