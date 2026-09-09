class SessionsController < ApplicationController
  def new
    render :new
  end

  # 初回ログイン時、bootstrap の 1 人目だけが admin になる。
  # 以降の新規ログインは全員 pending で、できることは何もない。
  def create
    auth = request.env.fetch("omniauth.auth")
    user = User.find_or_initialize_by(github_uid: auth.uid.to_s)
    user.assign_attributes(login: auth.info.nickname, name: auth.info.name, avatar_url: auth.info.image)
    user.role = :admin if user.new_record? && bootstrap_admin?(auth.info.nickname)
    user.save!

    _session, token = Session.issue!(user:, user_agent: request.user_agent, ip_address: request.remote_ip)
    cookies.signed[:session_token] = { value: token, httponly: true, same_site: :lax, secure: request.ssl? }

    redirect_to(session.delete(:return_to) || root_path)
  end

  def failure
    redirect_to login_path, alert: "GitHub のログインに失敗しました"
  end

  def destroy
    Current.session&.destroy
    cookies.delete(:session_token)

    redirect_to login_path
  end

  # 承認待ち画面。pending のユーザーはここで止まる
  def pending
    redirect_to(root_path) if current_user&.can_use_mcp?
  end

  private

  def bootstrap_admin?(login)
    expected = Rails.configuration.x.mcprb.bootstrap_admin_login
    expected.present? && expected == login
  end
end
