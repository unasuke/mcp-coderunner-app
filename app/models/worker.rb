# A worker's credential. Long-lived, and outlasts restarts.
# WorkerProcess holds the individual run.
class Worker < ApplicationRecord
  TOKEN_BYTES = 32

  has_many :worker_processes, foreign_key: :worker_id, primary_key: :worker_id,
    dependent: :destroy, inverse_of: false

  validates :worker_id, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # The plaintext is shown once, right there. Only the SHA256 is stored, so once
  # the page is closed it is gone for good; losing it means issuing a new one.
  # That does not add a row -- it replaces the digest on the same worker_id,
  # because past worker_processes and leases point at this row
  def self.issue!(worker_id:)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    worker = find_or_initialize_by(worker_id:)
    worker.token_digest = digest(token)
    # Re-issuing against a revoked worker_id puts it back in service under the new
    # token. The old one stops working the moment the digest changes
    worker.revoked_at = nil
    worker.save!

    [ worker, token ]
  end

  def self.authenticate(token)
    return nil if token.blank?

    active.find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  # The row stays. worker_processes and past leases refer to it
  def revoke!
    update!(revoked_at: Time.current)
  end

  def revoked?
    revoked_at.present?
  end
end
