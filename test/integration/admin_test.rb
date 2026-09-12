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

  # Under production-like configuration the developer sign-in does not exist.
  # It bypasses the center of the authorization model, so with the setting off the
  # route itself has to be gone
  test "the developer login is absent unless it is explicitly allowed" do
    refute Rails.configuration.x.mcp_coderunner_app.allow_developer_login

    post "/auth/developer"

    assert_response :not_found

    post "/auth/developer/callback", params: { nickname: "dev" }

    assert_response :not_found
    assert_nil Current.user
  end

  test "the first login becomes admin when it matches the bootstrap login" do
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = "unasuke"
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: "1", info: { nickname: "unasuke", name: nil, image: nil }
    )

    post "/auth/github"
    follow_redirect!

    assert_predicate User.find_by(github_uid: "1"), :admin?
  ensure
    Rails.configuration.x.mcp_coderunner_app.bootstrap_admin_login = nil
  end

  # Every sign-in after the first is pending, and can do nothing at all
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

  # A Dockerfile that cannot be built used to be found out by submitting a job and
  # waiting for image_build_failed. Approving queues that job itself, which also
  # leaves the image warm for the first real one
  test "approving a blueprint queues a job that builds it" do
    sign_in

    assert_difference -> { @blueprint.jobs.count }, 1 do
      post approve_admin_blueprint_path(@blueprint)
    end

    job = @blueprint.jobs.last

    assert_predicate job, :queued?
    assert_equal "default", job.profile
    assert_equal "unasuke", job.requested_by.login
    assert_equal Blueprints::Approve::VERIFICATION_SCRIPT, job.script
  end

  # The design has a job on an approved digest go straight through. A job submitted
  # before the review was done is held back by that and nothing else, so approving
  # is the answer to it -- being asked to approve the job as well is the same
  # question twice
  test "approving a blueprint releases the jobs that were waiting on it" do
    waiting = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default")
    sign_in

    post approve_admin_blueprint_path(@blueprint)

    assert_predicate waiting.reload, :queued?
    assert_equal "unasuke", waiting.approved_by.login
  end

  # bench asks for a human on its own account, and so does a script too large to
  # have been written to try something out. Neither reason goes away with approval
  test "a job that needs review for itself keeps waiting" do
    bench = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "bench")
    huge = Job.create!(blueprint: @blueprint, profile: "default",
      script: "x" * (Job.review_script_bytes + 1))
    sign_in

    post approve_admin_blueprint_path(@blueprint)

    assert_predicate bench.reload, :pending_review?
    assert_predicate huge.reload, :pending_review?
  end

  # Approval is a judgement about content and stands on its own. Rejecting one does
  # not queue anything
  test "rejecting a blueprint queues nothing" do
    sign_in

    assert_no_difference -> { Job.count } do
      post reject_admin_blueprint_path(@blueprint)
    end
  end

  test "an admin rejects a blueprint with a note" do
    sign_in

    post reject_admin_blueprint_path(@blueprint), params: { review_note: "curl | sh はだめ" }

    assert_predicate @blueprint.reload, :rejected?
    assert_equal "curl | sh はだめ", @blueprint.review_note
  end

  # Something revoked cannot be walked back to approved by a POST
  test "a revoked blueprint cannot be approved again" do
    sign_in
    @blueprint.update!(state: :revoked)

    post approve_admin_blueprint_path(@blueprint)

    assert_predicate @blueprint.reload, :revoked?
    assert_match(/revoked/, flash[:alert])
  end

  test "an approved blueprint cannot be rejected" do
    sign_in
    @blueprint.update!(state: :approved)

    post reject_admin_blueprint_path(@blueprint)

    assert_predicate @blueprint.reload, :approved?
  end

  test "a blueprint that was never approved cannot be revoked" do
    sign_in

    post revoke_admin_blueprint_path(@blueprint)

    assert_predicate @blueprint.reload, :pending_review?
  end

  test "an admin approves a job once its blueprint is approved" do
    sign_in
    @blueprint.update!(state: :approved)
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "bench")

    post approve_admin_job_path(job)

    assert_equal "queued", job.reload.state
  end

  # Naming a digest is enough to create a job against an unapproved Blueprint.
  # Without closing the path from there to execution, something could run without
  # anyone having read the Dockerfile
  test "a job on an unapproved blueprint cannot be approved" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default")

    post approve_admin_job_path(job)

    assert_equal "pending_review", job.reload.state
    assert_match(/実行環境/, flash[:alert])
  end

  test "a job on a revoked blueprint cannot be approved either" do
    sign_in
    @blueprint.update!(state: :revoked)
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default")

    post approve_admin_job_path(job)

    assert_equal "pending_review", job.reload.state
  end

  # A job that cannot be approved can still be rejected, so it does not pile up
  test "a job on an unapproved blueprint can still be rejected" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default")

    post reject_admin_job_path(job)

    assert_equal "rejected", job.reload.state
  end

  # A queued job is finished as cancelled right here. No worker is involved
  test "cancelling a queued job finishes it immediately" do
    sign_in
    job = Job.create!(blueprint: @blueprint, script: "puts 1", profile: "default", state: :queued)

    post cancel_admin_job_path(job)

    assert_equal "finished", job.reload.state
    assert_equal "cancelled", job.job_result.termination_reason
  end

  # A running job is only told to the worker, which picks it up in a heartbeat response
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

    worker = Worker.find_by(worker_id: "home-vm-01")

    assert_predicate worker, :present?
    # The plaintext is handed over once for display. What is stored is the hash
    assert_equal Worker.digest(flash[:issued_token]), worker.token_digest
  end

  # The plaintext appears once. Losing it means issuing a new one, without adding a row
  test "issuing a token again rotates it in place" do
    sign_in
    worker, first = Worker.issue!(worker_id: "home-vm-01")

    assert_difference -> { Worker.count }, 0 do
      post admin_workers_path, params: { worker_id: "home-vm-01" }
    end

    assert_nil Worker.authenticate(first)
    assert_equal worker, Worker.authenticate(flash[:issued_token])
  end

  test "re-issuing brings a revoked worker back with a new token" do
    sign_in
    _worker, old_token = Worker.issue!(worker_id: "home-vm-01")
    Worker.find_by(worker_id: "home-vm-01").revoke!

    post admin_workers_path, params: { worker_id: "home-vm-01" }

    assert_nil Worker.authenticate(old_token)
    assert_predicate Worker.authenticate(flash[:issued_token]), :present?
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
