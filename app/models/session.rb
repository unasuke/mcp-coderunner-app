class Session < ApplicationRecord
  TOKEN_BYTES = 32

  belongs_to :user

  # cookie に入れる平文はここでしか手に入らない。DB には SHA256 だけ残す
  def self.issue!(user:, user_agent: nil, ip_address: nil)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
    session = create!(
      user:,
      token_digest: digest(token),
      user_agent:,
      ip_address:,
      last_used_at: Time.current
    )
    [ session, token ]
  end

  def self.authenticate(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def touch_usage!
    update_column(:last_used_at, Time.current)
  end
end
