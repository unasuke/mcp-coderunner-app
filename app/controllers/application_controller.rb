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

  # /oauth/authorize と /admin の関門。
  # 未ログインなら GitHub へ、pending なら承認待ち画面で止める。
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

  # Doorkeeper の resource_owner_authenticator から呼ばれる
  def current_user_for_oauth
    current_user if current_user&.can_use_mcp?
  end
end
