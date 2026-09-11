require "application_system_test_case"

# 管理画面は人間しか通らない唯一の面で、承認はここにしかない。
# リクエストレベルの検証は test/integration/admin_test.rb にある。
# ここで見るのは、ブラウザを通さないと分からないことだけに絞る。
class AdminConsoleTest < ApplicationSystemTestCase
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "1", info: { nickname: "unasuke", name: "unasuke", image: nil }
    )
    # 1 人目だけが admin になる。ログインの経路ごと通す
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = "unasuke"
  end

  teardown do
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = nil
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.test_mode = false
  end

  # 承認は Blueprint から Job への一方向で、順番を飛ばせない。
  # 画面の上でも同じ順序でしか進めないことを見る
  test "a job stays unapprovable until its blueprint is approved" do
    blueprint = create_blueprint
    job = Job.create!(blueprint:, script: "puts 1\n", profile: "default")

    sign_in

    click_on "ジョブ"
    click_on job.id.to_s

    assert_text "承認するまで実行されません"
    assert_text "Dockerfile を読んで先に実行環境を承認してください"
    assert_no_button "承認して実行する"

    within("dl.facts") { click_on blueprint.name }

    assert_text blueprint.digest
    click_on "承認する"

    assert_text "approved"

    click_on "ジョブ"
    click_on job.id.to_s
    click_on "承認して実行する"

    assert_text "queued"
    assert_predicate job.reload, :queued?
  end

  # かつて meta http-equiv="refresh" で自動更新していた。あれはページを離れても
  # ブラウザ側のタイマーが生き残り、別の画面を見ているのに引き戻された。
  # Stimulus の disconnect で止まっていることを、実際に間隔をまたいで確かめる
  test "leaving a running job's page stops the auto refresh" do
    job = Job.create!(blueprint: create_blueprint(state: :approved), script: "puts 1\n",
      profile: "default", state: :running)

    sign_in
    visit admin_job_path(job)

    assert_text "5 秒ごとに更新"

    click_on "実行環境"

    assert_current_path admin_blueprints_path
    sleep 6  # 更新間隔 5 秒を 1 回またぐ
    assert_current_path admin_blueprints_path
  end

  # 承認は外出先の電話からでも通せる必要がある。横スクロールが出ると
  # 表の右端にある操作に届かない
  test "the console fits a phone-sized viewport" do
    job = Job.create!(blueprint: create_blueprint(state: :approved), script: "puts 1\n",
      profile: "default", state: :queued)

    sign_in
    resize_to_phone

    visit admin_jobs_path

    assert_link "ジョブ"
    assert_no_horizontal_overflow

    visit admin_job_path(job)

    assert_text "起動コマンド"
    assert_no_horizontal_overflow
  end

  private

  def create_blueprint(state: :pending_review)
    dockerfile = "FROM ruby:3.4-slim\nRUN echo #{state}\n"
    Blueprint.create!(name: "ruby", summary: "テスト用", dockerfile:, state:,
      digest: Blueprint.digest_for(dockerfile:, files: []))
  end

  def sign_in
    visit login_path
    click_on "GitHub でログイン"

    assert_text "unasuke（admin）"
  end

  def resize_to_phone
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  # 表や Dockerfile のような広いものは、それぞれの器の中で横スクロールさせる。
  # ページ全体が横に伸びていないことを見る
  def assert_no_horizontal_overflow
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )

    assert_operator overflow, :<=, 0, "ページ全体が横に #{overflow}px はみ出している"
  end
end
