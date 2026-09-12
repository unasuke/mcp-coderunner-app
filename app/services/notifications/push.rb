module Notifications
  # Web Push to every browser an admin has subscribed. Delivery is best-effort:
  # a push service is a third party that can be slow or gone, and none of this is
  # worth failing a review over.
  #
  # Without VAPID keys the whole thing is absent -- no button, no delivery, no
  # error. Same treatment as GitHub sign-in.
  class Push
    def self.configured?
      config.vapid_public_key.present? && config.vapid_private_key.present?
    end

    def self.config
      Rails.configuration.x.mcp_coderunner_app
    end

    # The contact a push service would use if something here were wrong. This site
    # answers that as well as an address does, and keeps a personal one out of a
    # JWT sent to Apple, Google and Mozilla
    def self.subject
      config.vapid_subject.presence || config.base_url
    end

    def self.to_admins(title:, body:, path:)
      return unless configured?

      PushSubscription.where(user: User.admin).find_each do |subscription|
        deliver(subscription, title:, body:, path:)
      end
    end

    def self.deliver(subscription, title:, body:, path:)
      WebPush.payload_send(
        message: JSON.generate(title:, options: { body:, data: { path: } }),
        vapid: { subject:, public_key: config.vapid_public_key,
                 private_key: config.vapid_private_key },
        urgency: "normal",
        **subscription.to_web_push
      )
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      # The browser is gone or was reset. The row is the only thing keeping it
      # alive, so let it go rather than retrying forever
      subscription.destroy
    rescue WebPush::Error => e
      Rails.logger.warn("[push] #{subscription.endpoint[0, 40]}...: #{e.class}: #{e.message}")
    end
    private_class_method :deliver
  end
end
