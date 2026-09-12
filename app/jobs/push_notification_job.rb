# Push delivery talks to a third party over the network, which is no business of
# the request that triggered it: proposing a Blueprint should not wait on a push
# service, nor fail because one is down.
class PushNotificationJob < ApplicationJob
  queue_as :default

  # Nothing is retried. A notification that arrives late is worth less than the
  # review page it points at, which is there either way
  discard_on StandardError

  def perform(title:, body:, path:)
    Notifications::Push.to_admins(title:, body:, path:)
  end
end
