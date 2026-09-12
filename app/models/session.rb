class Session < ApplicationRecord
  TOKEN_BYTES = 32

  # How long the browser is asked to keep the cookie. Without it the cookie lasts
  # only as long as the browser session, which on iOS means until Safari decides to
  # reclaim the tab -- so the phone asked for a GitHub sign-in on nearly every
  # visit while the session row sat here, perfectly valid.
  COOKIE_LIFETIME = 30.days

  belongs_to :user

  # This is the only place the plaintext for the cookie exists. Only the SHA256 is kept
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
