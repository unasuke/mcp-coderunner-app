class Lease < ApplicationRecord
  TOKEN_BYTES = 32
  RELEASE_REASONS = %w[ completed deregistered expired cancelled ].freeze

  belongs_to :job

  scope :active, -> { where(released_at: nil) }
  scope :held_by, ->(instance_id) { where(instance_id:) }
  scope :expired, ->(now = Time.current) { active.where(expires_at: ...now) }

  # 平文はワーカーにしか渡らない。短命だから平文でよい、とはしない。
  # 実行中のジョブの結果を差し替えられる値であり、/result を受け付ける唯一の根拠だから
  def self.issue!(job:, instance_id:, ttl: Protocol::Constants::LEASE_TTL)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    lease = create!(job:, instance_id:, token_digest: digest(token), expires_at: ttl.seconds.from_now)
    [ lease, token ]
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def authenticate(token)
    return false if token.blank?

    ActiveSupport::SecurityUtils.secure_compare(token_digest, self.class.digest(token))
  end

  def release!(reason)
    update!(released_at: Time.current, release_reason: reason)
  end

  def extend!(ttl: Protocol::Constants::LEASE_TTL)
    update!(expires_at: ttl.seconds.from_now)
  end

  def active?
    released_at.nil?
  end
end
