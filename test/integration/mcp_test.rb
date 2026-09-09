require "test_helper"

class McpTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(github_uid: "1", login: "unasuke", role: :member)
    @application = Doorkeeper::Application.create!(
      name: "claude", redirect_uri: "https://claude.ai/api/mcp/auth_callback", confidential: false
    )
    @token = Doorkeeper::AccessToken.create!(
      application: @application, resource_owner_id: @user.id, expires_in: 900, scopes: ""
    )
  end

  def rpc(method, params = {}, id: 1, token: @token.token)
    post "/mcp", headers: { "Authorization" => "Bearer #{token}" }, as: :json,
      params: { jsonrpc: "2.0", id:, method:, params: }
    response.parsed_body
  end

  def tool(name, arguments = {})
    body = rpc("tools/call", { name:, arguments: })
    content = body.dig("result", "content", 0, "text")
    [ JSON.parse(content), body.dig("result", "isError") ]
  end

  # 401 の WWW-Authenticate からリソースメタデータを指す（RFC 9728）
  test "an unauthenticated request points at the resource metadata" do
    post "/mcp", as: :json, params: { jsonrpc: "2.0", id: 1, method: "tools/list" }

    assert_response :unauthorized
    assert_match %r{resource_metadata="http://mcprb.invalid/\.well-known/oauth-protected-resource"},
      response.headers["WWW-Authenticate"]
  end

  test "initialize and tools/list" do
    assert_equal "mcprb", rpc("initialize", {
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

    # 名前だけ違う同一内容も同じ行に落ちる
    again, = tool("propose_blueprint", {
      name: "different-name", summary: "べつの説明", dockerfile: "FROM ruby:3.4-slim\n",
      files: [ { path: "Gemfile", content: "source 'https://rubygems.org'\n" } ]
    })

    refute again["created"]
    assert_equal payload["blueprint_id"], again["blueprint_id"]
    assert_equal "ruby-3.4", again["name"]
  end

  test "list_blueprints only returns approved ones" do
    Blueprint.create!(name: "waiting", summary: "x", dockerfile: "FROM a\n",
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []))
    approved = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)

    payload, = tool("list_blueprints")

    assert_equal [ approved.digest ], payload["blueprints"].map { |b| b["digest"] }
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

  # digest 指定なら未承認でも受け付ける。Job が pending_review に入る
  test "submit_job on an unapproved blueprint waits for review" do
    blueprint = Blueprint.create!(name: "waiting", summary: "x", dockerfile: "FROM a\n",
      digest: Blueprint.digest_for(dockerfile: "FROM a\n", files: []))

    payload, = tool("submit_job", { blueprint: blueprint.digest, script: "puts 1" })

    assert_equal "pending_review", payload["state"]
    assert_match %r{/admin/jobs/\d+}, payload["review_url"]
  end

  # bench は承認が要る
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

  # 保持期間を過ぎたことが応答から読めれば、結果が空なのを実行の失敗と誤読しない
  test "a purged job says so" do
    blueprint = Blueprint.create!(name: "ready", summary: "y", dockerfile: "FROM b\n",
      digest: Blueprint.digest_for(dockerfile: "FROM b\n", files: []), state: :approved)
    job = Job.create!(blueprint:, script: "", profile: "default", state: :finished, purged_at: Time.current)

    payload, = tool("get_job", { job_id: job.id })

    assert payload["purged_at"]
    assert_nil payload["stdout"]
  end

  test "the oauth metadata is public" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal "http://mcprb.invalid/mcp", response.parsed_body["resource"]

    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_equal [ "S256" ], response.parsed_body["code_challenge_methods_supported"]
    assert_equal "http://mcprb.invalid/oauth/register", response.parsed_body["registration_endpoint"]
  end

  test "dynamic client registration issues a public client" do
    post "/oauth/register", as: :json, params: {
      client_name: "Claude", redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ]
    }

    assert_response :created
    assert_equal "none", response.parsed_body["token_endpoint_auth_method"]
    assert_predicate Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"]), :present?
  end

  test "dynamic client registration refuses a plaintext redirect_uri" do
    post "/oauth/register", as: :json, params: { redirect_uris: [ "http://evil.invalid/cb" ] }

    assert_response :bad_request
  end
end
