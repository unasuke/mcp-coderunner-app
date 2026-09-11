require "application_system_test_case"

# The admin console is the only surface a human touches, and approval lives nowhere
# else. The request-level checks are in test/integration/admin_test.rb. What is here
# is kept to what cannot be seen without a browser.
class AdminConsoleTest < ApplicationSystemTestCase
  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "1", info: { nickname: "unasuke", name: "unasuke", image: nil }
    )
    # Only the first user becomes admin. This walks the whole sign-in path
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = "unasuke"
  end

  teardown do
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = nil
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.test_mode = false
  end

  # Approval runs one way, Blueprint before Job, and the order cannot be skipped.
  # This watches that the screen allows no other sequence either
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

  # This used to refresh through meta http-equiv="refresh". That timer outlived the
  # page: it kept firing after a visit elsewhere and pulled the reader back mid-read.
  # This waits past the interval to see that Stimulus's disconnect really stopped it
  test "leaving a running job's page stops the auto refresh" do
    job = Job.create!(blueprint: create_blueprint(state: :approved), script: "puts 1\n",
      profile: "default", state: :running)

    sign_in
    visit admin_job_path(job)

    assert_text "5 秒ごとに更新"

    click_on "実行環境"

    assert_current_path admin_blueprints_path
    sleep 6  # one tick past the 5-second interval
    assert_current_path admin_blueprints_path
  end

  # Approving has to work from a phone, away from a desk. A horizontal scrollbar
  # puts the actions at the right edge of a table out of reach
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

  # Wide things -- tables, Dockerfiles -- scroll sideways inside their own container.
  # What this watches is that the page as a whole does not
  def assert_no_horizontal_overflow
    overflow = page.evaluate_script(
      "document.documentElement.scrollWidth - document.documentElement.clientWidth"
    )

    assert_operator overflow, :<=, 0, "ページ全体が横に #{overflow}px はみ出している"
  end
end
