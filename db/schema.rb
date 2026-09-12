# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_12_060000) do
  create_table "blueprint_files", force: :cascade do |t|
    t.integer "blueprint_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.boolean "executable", default: false, null: false
    t.string "path", null: false
    t.datetime "updated_at", null: false
    t.index ["blueprint_id", "path"], name: "index_blueprint_files_on_blueprint_id_and_path", unique: true
    t.index ["blueprint_id"], name: "index_blueprint_files_on_blueprint_id"
  end

  create_table "blueprints", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.string "digest", null: false
    t.text "dockerfile", null: false
    t.string "name", null: false
    t.integer "oauth_application_id"
    t.integer "parent_id"
    t.text "review_note"
    t.datetime "reviewed_at"
    t.integer "reviewed_by_id"
    t.string "state", default: "pending_review", null: false
    t.string "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_blueprints_on_created_by_id"
    t.index ["digest"], name: "index_blueprints_on_digest", unique: true
    t.index ["name", "state", "created_at"], name: "index_blueprints_on_name_and_state_and_created_at"
    t.index ["oauth_application_id"], name: "index_blueprints_on_oauth_application_id"
    t.index ["parent_id"], name: "index_blueprints_on_parent_id"
    t.index ["reviewed_by_id"], name: "index_blueprints_on_reviewed_by_id"
  end

  create_table "job_results", force: :cascade do |t|
    t.json "applied_limits", null: false
    t.integer "cpu_time_ms"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.integer "exit_code"
    t.string "image_digest"
    t.integer "job_id", null: false
    t.bigint "max_rss_bytes"
    t.text "stderr"
    t.text "stdout"
    t.string "termination_reason", null: false
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "worker_id"
    t.index ["job_id"], name: "index_job_results_on_job_id", unique: true
  end

  create_table "jobs", force: :cascade do |t|
    t.integer "approved_by_id"
    t.integer "blueprint_id", null: false
    t.datetime "cancel_requested_at"
    t.datetime "created_at", null: false
    t.json "entrypoint"
    t.integer "oauth_application_id"
    t.string "profile", null: false
    t.datetime "purged_at"
    t.integer "requested_by_id"
    t.text "script", null: false
    t.string "state", default: "pending_review", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_jobs_on_approved_by_id"
    t.index ["blueprint_id"], name: "index_jobs_on_blueprint_id"
    t.index ["oauth_application_id"], name: "index_jobs_on_oauth_application_id"
    t.index ["requested_by_id"], name: "index_jobs_on_requested_by_id"
    t.index ["state", "created_at"], name: "index_jobs_on_state_and_created_at"
  end

  create_table "leases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "instance_id", null: false
    t.integer "job_id", null: false
    t.string "release_reason"
    t.datetime "released_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["instance_id", "released_at"], name: "index_leases_on_instance_id_and_released_at"
    t.index ["job_id"], name: "index_leases_on_job_id"
    t.index ["job_id"], name: "index_leases_on_job_id_active", unique: true, where: "released_at IS NULL"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.integer "application_id", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.integer "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.integer "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.integer "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key", null: false
    t.datetime "created_at", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_used_at", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "approved_at"
    t.integer "approved_by_id"
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "github_uid", null: false
    t.string "login", null: false
    t.string "name"
    t.string "role", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_users_on_approved_by_id"
    t.index ["github_uid"], name: "index_users_on_github_uid", unique: true
  end

  create_table "worker_processes", force: :cascade do |t|
    t.integer "capacity", null: false
    t.string "commit_hash", null: false
    t.datetime "created_at", null: false
    t.string "docker_version"
    t.string "hostname"
    t.string "instance_id", null: false
    t.datetime "last_heartbeat_at", null: false
    t.json "metadata"
    t.integer "pid"
    t.integer "protocol_version", null: false
    t.string "ruby_version"
    t.datetime "started_at", null: false
    t.datetime "stopped_at"
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.index ["instance_id"], name: "index_worker_processes_on_instance_id", unique: true
    t.index ["worker_id", "last_heartbeat_at"], name: "index_worker_processes_on_worker_id_and_last_heartbeat_at"
  end

  create_table "workers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id", null: false
    t.index ["token_digest"], name: "index_workers_on_token_digest", unique: true
    t.index ["worker_id"], name: "index_workers_on_worker_id", unique: true
  end

  add_foreign_key "blueprint_files", "blueprints"
  add_foreign_key "blueprints", "blueprints", column: "parent_id"
  add_foreign_key "blueprints", "oauth_applications"
  add_foreign_key "blueprints", "users", column: "created_by_id"
  add_foreign_key "blueprints", "users", column: "reviewed_by_id"
  add_foreign_key "job_results", "jobs"
  add_foreign_key "jobs", "blueprints"
  add_foreign_key "jobs", "oauth_applications"
  add_foreign_key "jobs", "users", column: "approved_by_id"
  add_foreign_key "jobs", "users", column: "requested_by_id"
  add_foreign_key "leases", "jobs"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "users", column: "approved_by_id"
end
