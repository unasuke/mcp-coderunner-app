class SessionsController < ApplicationController
  # The developer sign-in's callback is POSTed from a form OmniAuth generated, so it
  # carries no Rails authenticity token. Skipping it rests on the door itself being
  # shut by configuration.
  skip_before_action :verify_authenticity_token, only: :developer

  def new
    render :new
  end

  # The callback from GitHub
  def create
    sign_in_with(request.env.fetch("omniauth.auth"))
  end

  # The development door that skips GitHub. It exists only where configuration
  # allows it. Without the strategy registered nothing sets omniauth.auth either,
  # so it is shut twice over.
  def developer
    return head(:not_found) unless Rails.configuration.x.mcp_coderunner_app.allow_developer_login

    sign_in_with(request.env.fetch("omniauth.auth"))
  end

  # Where the request lands when OmniAuth has no GitHub strategy registered
  def github
    redirect_to login_path,
      alert: "GitHub ログインが設定されていません。GITHUB_CLIENT_ID と GITHUB_CLIENT_SECRET を入れて再起動してください"
  end

  def failure
    redirect_to login_path, alert: "GitHub のログインに失敗しました"
  end

  def destroy
    Current.session&.destroy
    cookies.delete(:session_token)

    redirect_to login_path
  end

  # The waiting-for-approval page, where a pending user stops
  def pending
    redirect_to(root_path) if current_user&.can_use_mcp?
  end

  private

  # On a first sign-in, only the bootstrap login becomes admin.
  # Every new sign-in after that is pending, and can do nothing at all.
  def sign_in_with(auth)
    user = User.find_or_initialize_by(github_uid: auth.uid.to_s)
    user.assign_attributes(login: auth.info.nickname, name: auth.info.name, avatar_url: auth.info.image)
    user.role = :admin if user.new_record? && bootstrap_admin?(auth.info.nickname)
    user.save!

    _session, token = Session.issue!(user:, user_agent: request.user_agent, ip_address: request.remote_ip)
    cookies.signed[:session_token] = {
      value: token, httponly: true, same_site: :lax, secure: request.ssl?,
      expires: Session::COOKIE_LIFETIME.from_now
    }

    redirect_to(session.delete(:return_to) || root_path)
  end

  def bootstrap_admin?(login)
    expected = Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login
    expected.present? && expected == login
  end
end
