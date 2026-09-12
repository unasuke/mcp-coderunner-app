# One browser that agreed to be told about something. Subscriptions belong to a
# browser rather than to a person: the same admin on a laptop and a phone is two
# rows, and either can be revoked from its own side without touching the other.
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, :auth_key, presence: true

  # Subscribing again from a browser that already has a row hands back the same
  # endpoint, so take the new keys rather than refusing it: a browser may rotate
  # them on its own.
  def self.record!(user:, endpoint:, p256dh_key:, auth_key:, user_agent: nil)
    subscription = find_or_initialize_by(endpoint:)
    subscription.update!(user:, p256dh_key:, auth_key:, user_agent:)
    subscription
  end

  def to_web_push
    { endpoint:, p256dh: p256dh_key, auth: auth_key }
  end
end
