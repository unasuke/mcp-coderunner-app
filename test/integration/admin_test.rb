require "test_helper"

class AdminTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @blueprint = Blueprint.create!(name: "ruby", summary: "test", dockerfile: "FROM ruby:3.4-slim\n",
      digest: Blueprint.digest_for(dockerfile: "FROM ruby:3.4-slim\n", files: []))
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  def sign_in(login: "unasuke", uid: "1", role: :admin)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: uid, info: { nickname: login, name: login, image: nil }
    )
    post "/auth/github"
    follow_redirect!
    User.find_by(github_uid: uid).update!(role:)
  end

  # 本番相当の設定では開発用ログインの口が存在しない。
  # これは認可の中心を迂回する口なので、設定が無効なら経路ごと消えていること
  test "the developer login is absent unless it is explicitly allowed" do
    refute Rails.configuration.x.mcprb.allow_developer_login

    post "/auth/developer"

    assert_response :not_found

    post "/auth/developer/callback", params: { nickname: "dev" }

    assert_response :not_found
    assert_nil Current.user
  end

  test "the first login becomes admin when it matches the bootstrap login" do
    Rails.configuration.x.mcprb.bootstrap_admin_login = "unasuke"
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "1", info: { nickname: "unasuke", name: nil, image: nil }
    )

    post "/auth/github"
    follow_redirect!

    assert_predicate User.find_by(github_uid: "1"), :admin?
  ensure
    Rails.configuration.x.mcprb.bootstrap_admin_login = nil
  end

  # 以降の新規ログインは全員 pending。できることは何もない
  test "later logins land on pending and cannot reach admin" do
    sign_in(role: :pending)

    get "/admin/jobs"

    assert_redirected_to pending_path
  end

  test "anonymous visitors are sent to login" do
    get "/admin/jobs"

    assert_redirected_to login_path
  end

  test "a member is not an admin" do
    sign_in(role: :member)

    get "/admin/blueprints"

    assert_response :forbidden
  end

  test "an admin approves a blueprint" do
    sign_in

    post approve_admin_blueprint_path(@blueprint)

    assert_predicate @blueprint.reload, :approved?
    assert_equal "unasuke", @blueprint.reviewed_by.login
  end

  test "an admin rejects a blueprint with a note" do
    sign_in

    post reject_admin_blueprint_path(@blueprint), params: { review_note: "curl | sh はだめ" }

    assert_predicate @blueprint.reload, :rejected?
    assert_equal "curl | sh はだめ", @blueprint.review_note
  end

  test "an admin approves a job so it becomes queued" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "bench")

    post approve_admin_job_path(job)

    assert_equal "queued", job.reload.state
  end

  # queued はその場で finished（cancelled）にする。ワーカーは関与しない
  test "cancelling a queued job finishes it immediately" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :queued)

    post cancel_admin_job_path(job)

    assert_equal "finished", job.reload.state
    assert_equal "cancelled", job.job_result.termination_reason
  end

  # running はワーカーに伝えるだけ。heartbeat の応答で拾わせる
  test "cancelling a running job only records the request" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :running)

    post cancel_admin_job_path(job)

    assert_predicate job.reload, :cancel_requested?
    assert_equal "running", job.state
  end

  test "an admin issues a worker token once" do
    sign_in

    post admin_workers_path, params: { worker_id: "home-vm-01" }

    assert_predicate Worker.find_by(worker_id: "home-vm-01"), :present?
    assert_match(/トークンを発行しました/, flash[:notice])
  end

  test "promoting a user drops their sessions when they lose access" do
    sign_in
    other = User.create!(github_uid: "2", login: "someone", role: :member)
    Session.issue!(user: other)

    patch admin_user_path(other, role: "pending")

    assert_predicate other.reload, :pending?
    assert_equal 0, other.sessions.count
  end
end
