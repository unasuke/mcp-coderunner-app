# ワーカーの資格情報。長命で、再起動をまたいで残る。
# 起動ごとの実体は WorkerProcess が持つ。
class Worker < ApplicationRecord
  TOKEN_BYTES = 32

  has_many :worker_processes, foreign_key: :worker_id, primary_key: :worker_id,
    dependent: :destroy, inverse_of: false

  validates :worker_id, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # 平文はその場で 1 度だけ表示する。DB に入るのは SHA256 だけなので、閉じたら二度と見られない。
  # 無くしたら再発行する。行は増やさず、同じ worker_id のダイジェストを差し替える
  # （過去の worker_processes と leases がこの行を指しているため）
  def self.issue!(worker_id:)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    worker = find_or_initialize_by(worker_id:)
    worker.token_digest = digest(token)
    # 失効させた worker_id に再発行したら、新しいトークンで使えるようにする。
    # 古いトークンはダイジェストが変わった時点で通らない
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

  # 行は消さない。worker_processes と過去の leases から参照される
  def revoke!
    update!(revoked_at: Time.current)
  end

  def revoked?
    revoked_at.present?
  end
end
