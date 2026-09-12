module Admin
  # One browser's agreement to be notified. The browser is the only thing that
  # knows its own endpoint, so it hands that back when it wants out.
  class PushSubscriptionsController < BaseController
    def create
      PushSubscription.record!(
        user: current_user,
        endpoint: params.require(:endpoint),
        p256dh_key: params.require(:p256dh),
        auth_key: params.require(:auth),
        user_agent: request.user_agent
      )

      head :created
    end

    def destroy
      current_user.push_subscriptions.find_by(endpoint: params[:endpoint])&.destroy

      head :no_content
    end
  end
end
