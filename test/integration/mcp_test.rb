require "test_helper"

class McpTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(github_uid: "1", login: "unasuke", role: :member)
    @application = Doorkeeper::Application.create!(
      name: "claude", redirect_uri: "https://claude.ai/api/mcp/auth_callback", confidential: false
    )
    @token = Doorkeeper::AccessToken.create!(
      application: @application, resource_owner_id: @user.id, expires_in: 900,
      scopes: Doorkeeper.config.default_scopes.to_s
    )
  end

  def rpc(method, params = {}, id: 1, token: @token.plaintext_token)
    post "/mcp", headers: { "Authorization" => "Bearer #{token}" }, as: :json,
      params: { jsonrpc: "2.0", id:, method:, params: }
    response.parsed_body
  end

  def tool(name, arguments = {})
    body = rpc("tools/call", { name:, arguments: })
    content = body.dig("result", "content", 0, "text")
    [ JSON.parse(content), body.dig("result", "isError") ]
  end

  # The WWW-Authenticate of a 401 points at the resource metadata (RFC 9728)
  test "an unauthenticated request points at the resource metadata" do
    post "/mcp", as: :json, params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :unauthorized
    assert_match %r{resource_metadata="http://mcp-coderunner-app.invalid/\.well-known/oauth-protected-resource"},
      response.headers["WWW-Authenticate"]
  end

  test "initialize and tools/list" do
    assert_equal "mcp-coderunner-app", rpc("initialize", {
      protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" }
    }).dig("result", "serverInfo", "name")

    names = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }

    assert_equal %w[list_blueprints propose_blueprint submit_job get_job], names
  end

  test "propose_blueprint is idempotent and records the proposer" do
    payload, error = tool("propose_blueprint", {
      name: "ruby-3.4", summary: "Ractor の検証用", dockerfile: "FROM ruby:3.4-slim\n",
      files: [ { path: "Gemfile", content: "source 'https://rubygems.org'\n" } ]
    })

    refute error
    assert_equal "pending_review", payload["state"]
    assert payload["created"]
    assert_match %r{/admin/blueprints/\d+}, payload["review_url"]

    blueprint = Blueprint.find(payload["blueprint_id"])
    assert_equal @user, blueprint.created_by
    assert_equal @application, blueprint.oauth_application

    # Identical content under a different name lands on the same row
    again, = tool("propose_blueprint", {
      name: "different-name", summary: "べつの説明", dockerfile: "FROM ruby:3.4-slim\n",
      files: [ { path: "Gemfile", content: "source 'https://rubygems.org'\n" } ]
    })

    refute again["created"]
    assert_equal payload["blueprint_id"], again["blueprint_id"]
    assert_equal "ruby-3.4", again["name"]
  end

  # Chained to the previous revision under the same name, so /admin can review it as a diff
  test "a second proposal under the same name links to the previous one" do
    first, = tool("propose_blueprint", {
      name: "ruby-3.4", summary: "最初の版", dockerfile: "FROM ruby:3.4-slim\n"
    })
    second, = tool("propose_blueprint", {
      name: "ruby-3.4", summary: "依存を足した版", dockerfile: "FROM ruby:3.4-slim\nRUN bundle install\n"
    })

    assert second["created"]
    assert_equal first["blueprint_id"], Blueprint.find(second["blueprint_id"]).parent_id
  end

  # Nothing else tells a human that something is waiting for them
  test "proposing a blueprint asks the admins to come and look" do
    assert_enqueued_with(job: PushNotificationJob) do
      tool("propose_blueprint", { name: "ruby", summary: "x", dockerfile: "FROM ruby:3.4-slim\n" })
    end
  end

  # The same content proposed again returns the row that is already there. That is
  # not news, and a notification for it would train its reader to ignore them
  test "proposing the same content again notifies nobody" do
    payload = { name: "ruby", summary: "x", dockerfile: "FROM ruby:3.4-slim\n" }
    tool("propose_blueprint", payload)

    assert_no_enqueued_jobs(only: PushNotificationJob) do
      tool("propose_blueprint", payload.merge(name: "another-name"))
    end
  end

  test "list_blueprints only returns approved ones" do
    Blueprint.create!(name: "waiting", summary: "x", dockerfile: "FROM a\n",
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []))
    approved = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)

    payload, = tool("list_blueprints")

    assert_equal [ approved.digest ], payload["blueprints"].map { |b| b["digest"] }
  end

  # The build check queued at approval time is what usually fills this in. Without
  # it a client cannot tell a broken script from an environment that will not build
  test "list_blueprints reports what happened last on each environment" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    job = Job.create!(blueprint:, script: "puts 1", profile: "default", state: :finished)
    job.create_job_result!(termination_reason: "image_build_failed", applied_limits: {})

    payload, = tool("list_blueprints")

    assert_equal "image_build_failed", payload["blueprints"].first.dig("last_result", "termination_reason")
  end

  test "list_blueprints leaves last_result null before anything has run" do
    Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)

    payload, = tool("list_blueprints")

    assert_nil payload["blueprints"].first["last_result"]
  end

  # Told at submission time, a client can stop rewriting a script that was never
  # the problem
  test "submit_job carries the environment's last result" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    failed = Job.create!(blueprint:, script: "puts 1", profile: "default", state: :finished)
    failed.create_job_result!(termination_reason: "image_build_failed", applied_limits: {})

    payload, error = tool("submit_job", { blueprint: blueprint.digest, script: "puts 2" })

    refute error
    assert_equal "image_build_failed", payload.dig("blueprint_last_result", "termination_reason")
  end

  test "submit_job queues on an approved blueprint" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)

    payload, error = tool("submit_job", { blueprint: "ready", script: "puts 1" })

    refute error
    assert_equal "queued", payload["state"]
    assert_equal blueprint.digest, payload["blueprint_digest"]
    assert_nil payload["review_url"]
  end

  # Naming a digest is accepted even unapproved. The job lands in pending_review
  test "submit_job on an unapproved blueprint waits for review" do
    blueprint = Blueprint.create!(name: "waiting", summary: "x", dockerfile: "FROM a\n",
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []))

    payload, = tool("submit_job", { blueprint: blueprint.digest, script: "puts 1" })

    assert_equal "pending_review", payload["state"]
    assert_match %r{/admin/jobs/\d+}, payload["review_url"]
  end

  # Content already turned down cannot be submitted again by anyone holding the digest
  test "submit_job refuses a rejected or revoked blueprint" do
    rejected = Blueprint.create!(name: "no", summary: "x", dockerfile: "FROM a\n",
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []),
      state: :rejected, review_note: "curl | sh はだめ")
    revoked = Blueprint.create!(name: "gone", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :revoked)

    assert_no_difference -> { Job.count } do
      payload, error = tool("submit_job", { blueprint: rejected.digest, script: "puts 1" })

      assert error
      assert_equal "not_approved", payload["error"]
      assert_equal "curl | sh はだめ", payload["review_note"]

      payload, error = tool("submit_job", { blueprint: revoked.digest, script: "puts 1" })

      assert error
      assert_equal "not_approved", payload["error"]
    end
  end

  # bench needs approval
  test "the bench profile waits for review" do
    Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)

    payload, = tool("submit_job", { blueprint: "ready", script: "puts 1", profile: "bench" })

    assert_equal "pending_review", payload["state"]
  end

  test "errors come back in the body with a code" do
    missing, error = tool("submit_job", { blueprint: "nope", script: "puts 1" })

    assert error
    assert_equal "not_approved", missing["error"]

    unknown, error = tool("get_job", { job_id: 999 })

    assert error
    assert_equal "job_not_found", unknown["error"]

    Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    too_big, error = tool("submit_job", {
      blueprint: "ready", script: "x" * (Job.max_script_bytes + 1)
    })

    assert error
    assert_equal "script_too_large", too_big["error"]
  end

  test "get_job reports the result with the applied limits" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    job = Job.create!(blueprint:, script: "puts 1", profile: "default", state: :finished)
    JobResult.create!(job:, termination_reason: "oom_killed", exit_code: 137, stdout: "", stderr: "",
      duration_ms: 4210, applied_limits: { "memory_mb" => 2048 })

    payload, = tool("get_job", { job_id: job.id })

    assert_equal "oom_killed", payload["termination_reason"]
    assert_equal({ "memory_mb" => 2048 }, payload["applied_limits"])
  end

  # With retention visible in the response, an empty result is not misread as a
  # failed run. Losing the termination reason too would make it indistinguishable
  # from "no result yet"
  test "a purged job keeps its reason and says the body is gone" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    job = Job.create!(blueprint:, script: "puts 1", profile: "default", state: :finished,
      created_at: 100.days.ago, updated_at: 100.days.ago)
    JobResult.create!(job:, termination_reason: "oom_killed", exit_code: 137, stdout: "x" * 100,
      stderr: "", applied_limits: { "memory_mb" => 2048 }, created_at: 40.days.ago)

    RetentionJob.new.perform
    payload, = tool("get_job", { job_id: job.id })

    assert payload["purged_at"]
    assert_equal "oom_killed", payload["termination_reason"]
    assert_equal 137, payload["exit_code"]
    assert_nil payload["stdout"]
    assert_nil payload["stderr"]
  end

  test "the oauth metadata is public" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal "http://mcp-coderunner-app.invalid/mcp", response.parsed_body["resource"]

    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_equal [ "S256" ], response.parsed_body["code_challenge_methods_supported"]
    assert_equal [ "mcp" ], response.parsed_body["scopes_supported"]
    assert_equal "http://mcp-coderunner-app.invalid/oauth/register", response.parsed_body["registration_endpoint"]
  end

  # What someone is allowed to do is not left to a token's 15-minute lifetime. Even
  # by a path that never calls revoke -- an update straight from the console, say --
  # it stops at once
  test "a live token is refused once the user is no longer a member" do
    assert_equal 4, rpc("tools/list").dig("result", "tools").size

    @user.update!(role: :pending)

    post "/mcp", headers: { "Authorization" => "Bearer #{@token.plaintext_token}" }, as: :json,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  # A demotion from the admin console cuts the tokens as well
  test "demotion revokes the tokens, so refreshing does not get a new one" do
    @user.approve!(by: @user, role: :pending)

    assert_predicate @token.reload, :revoked?

    post "/mcp", headers: { "Authorization" => "Bearer #{@token.plaintext_token}" }, as: :json,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :unauthorized
  end

  test "a revoked refresh token cannot be exchanged" do
    refresh = Doorkeeper::AccessToken.create!(
      application: @application, resource_owner_id: @user.id, expires_in: 900,
      scopes: Doorkeeper.config.default_scopes.to_s, use_refresh_token: true
    )

    @user.approve!(by: @user, role: :pending)

    assert_predicate refresh.reload, :revoked?

    post "/oauth/token", params: {
      grant_type: "refresh_token", refresh_token: refresh.plaintext_refresh_token,
      client_id: @application.uid
    }

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  # A token short of the default scope gets a 403 in JSON, not an HTML error page
  test "a token without the scope is forbidden" do
    scopeless = Doorkeeper::AccessToken.create!(
      application: @application, resource_owner_id: @user.id, expires_in: 900, scopes: ""
    )

    post "/mcp", headers: { "Authorization" => "Bearer #{scopeless.plaintext_token}" }, as: :json,
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  test "dynamic client registration issues a public client" do
    post "/oauth/register", as: :json, params: {
      client_name: "Claude", redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ]
    }

    assert_response :created
    assert_equal "none", response.parsed_body["token_endpoint_auth_method"]
    assert_equal "mcp", response.parsed_body["scope"]
    assert_predicate Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"]), :present?
  end

  # No SSE stream is offered, so 405 (a MUST in the specification)
  test "GET and DELETE on the endpoint are refused with 405" do
    get "/mcp", headers: { "Authorization" => "Bearer #{@token.plaintext_token}" }

    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]

    delete "/mcp", headers: { "Authorization" => "Bearer #{@token.plaintext_token}" }

    assert_response :method_not_allowed
  end

  # Some clients ask with the resource path appended
  test "the resource metadata also answers under the resource path" do
    get "/.well-known/oauth-protected-resource/mcp"

    assert_response :success
    assert_equal "http://mcp-coderunner-app.invalid/mcp", response.parsed_body["resource"]

    get "/.well-known/oauth-authorization-server/mcp"

    assert_response :success
    assert_equal "http://mcp-coderunner-app.invalid", response.parsed_body["issuer"]
  end

  test "dynamic client registration refuses a plaintext redirect_uri" do
    post "/oauth/register", as: :json, params: { redirect_uris: [ "http://evil.invalid/cb" ] }

    assert_response :bad_request
  end
end
