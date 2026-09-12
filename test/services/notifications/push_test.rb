require "test_helper"

class Notifications::PushTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(github_uid: "1", login: "unasuke", role: :admin)
    @subscription = subscribe(@admin, "https://push.example.invalid/a")
    configure(public_key: "pub", private_key: "priv")
  end

  teardown { configure(public_key: nil, private_key: nil) }

  test "every admin browser is told, and nobody else's" do
    member = User.create!(github_uid: "2", login: "someone", role: :member)
    subscribe(member, "https://push.example.invalid/b")
    subscribe(@admin, "https://push.example.invalid/c")

    endpoints = []
    with_web_push ->(**args) { endpoints << args.fetch(:endpoint) } do
      Notifications::Push.to_admins(title: "t", body: "b", path: "/admin/blueprints/1")
    end

    assert_equal [ "https://push.example.invalid/a", "https://push.example.invalid/c" ], endpoints.sort
  end

  # Without keys the feature is absent rather than broken, the same way GitHub
  # sign-in is when it has no credentials
  test "nothing is sent when there are no keys" do
    configure(public_key: nil, private_key: nil)

    with_web_push ->(**) { flunk "sent a notification with no VAPID keys" } do
      Notifications::Push.to_admins(title: "t", body: "b", path: "/")
    end

    refute_predicate Notifications::Push, :configured?
  end

  # The row is the only thing keeping a dead browser alive. Retrying it forever
  # would be the alternative
  test "a subscription the push service has given up on is dropped" do
    with_web_push ->(**) { raise WebPush::ExpiredSubscription.new(gone_response, "push.example.invalid") } do
      Notifications::Push.to_admins(title: "t", body: "b", path: "/")
    end

    assert_empty PushSubscription.where(id: @subscription.id)
  end

  # A push service being slow or broken is not the review's problem
  test "any other failure leaves the subscription alone" do
    with_web_push ->(**) { raise WebPush::PushServiceError.new(gone_response, "push.example.invalid") } do
      Notifications::Push.to_admins(title: "t", body: "b", path: "/")
    end

    assert_predicate @subscription.reload, :present?
  end

  private

  # minitest 6 no longer ships Object#stub, and one seam does not justify a gem
  def with_web_push(behaviour)
    original = WebPush.method(:payload_send)
    WebPush.define_singleton_method(:payload_send) { |**args| behaviour.call(**args) }

    yield
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end

  def gone_response
    Struct.new(:code, :body).new("410", "gone")
  end

  def subscribe(user, endpoint)
    PushSubscription.create!(user:, endpoint:, p256dh_key: "p", auth_key: "a")
  end

  def configure(public_key:, private_key:)
    config = Rails.configuration.x.mcp_coderunner_app
    config.vapid_public_key = public_key
    config.vapid_private_key = private_key
  end
end
