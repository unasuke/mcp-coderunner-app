class SessionsController < ApplicationController
  # 開発用ログインのコールバックは OmniAuth が生成したフォームから POST で来るので、
  # Rails の authenticity token を持たない。この口自体が設定で塞がっている前提で外す。
  skip_before_action :verify_authenticity_token, only: :developer

  def new
    render :new
  end

  # GitHub からのコールバック
  def create
    sign_in_with(request.env.fetch("omniauth.auth"))
  end

  # GitHub を経由しない開発用の口。設定で許可された環境にしか無い。
  # ストラテジが生えていなければ omniauth.auth も来ないので、二重に閉じている。
  def developer
    return head(:not_found) unless Rails.configuration.x.mcp_coderunner_app.allow_developer_login

    sign_in_with(request.env.fetch("omniauth.auth"))
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

  # 初回ログイン時、bootstrap の 1 人目だけが admin になる。
  # 以降の新規ログインは全員 pending で、できることは何もない。
  def sign_in_with(auth)
    user = User.find_or_initialize_by(github_uid: auth.uid.to_s)
    user.assign_attributes(login: auth.info.nickname, name: auth.info.name, avatar_url: auth.info.image)
    user.role = :admin if user.new_record? && bootstrap_admin?(auth.info.nickname)
    user.save!

    _session, token = Session.issue!(user:, user_agent: request.user_agent, ip_address: request.remote_ip)
    cookies.signed[:session_token] = { value: token, httponly: true, same_site: :lax, secure: request.ssl? }

    redirect_to(session.delete(:return_to) || root_path)
  end

  def bootstrap_admin?(login)
    expected = Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login
    expected.present? && expected == login
  end
end
