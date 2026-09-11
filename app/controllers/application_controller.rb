class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_current_user

  helper_method :current_user

  private

  def set_current_user
    Current.session = Session.authenticate(cookies.signed[:session_token])
    Current.session&.touch_usage!
    Current.user = Current.session&.user
  end

  def current_user
    Current.user
  end

  # The gate in front of /oauth/authorize and /admin.
  # Not signed in goes to GitHub; pending stops at the waiting-for-approval page.
  def require_member!
    return if current_user&.can_use_mcp?

    if current_user
      redirect_to pending_path
    else
      session[:return_to] = request.fullpath
      redirect_to login_path
    end
  end

  def require_admin!
    return if current_user&.admin?

    require_member! || head(:forbidden)
  end

  # Called from Doorkeeper's resource_owner_authenticator.
  # Redirecting and returning nil is how Doorkeeper is told to stop here.
  def authenticate_resource_owner_for_oauth
    return current_user if current_user&.can_use_mcp?

    require_member!
    nil
  end
end
