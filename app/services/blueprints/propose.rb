module Blueprints
  # Proposing is treated as idempotent: an existing digest returns that row rather
  # than creating another. Since name is not part of the digest, identical content
  # under a different name lands here too.
  class Propose
    Result = Data.define(:blueprint, :created)

    def self.call(...) = new(...).call

    def initialize(name:, summary:, dockerfile:, files:, user: nil, oauth_application: nil)
      @name = name
      @summary = summary
      @dockerfile = dockerfile.to_s
      @files = files.map { |file| file.transform_keys(&:to_sym) }
      @user = user
      @oauth_application = oauth_application
    end

    def call
      validate!

      digest = Blueprint.digest_for(dockerfile: @dockerfile, files: @files)
      existing = Blueprint.find_by(digest:)
      # The name that comes back is the existing row's. A new name does not overwrite it
      return Result.new(blueprint: existing, created: false) if existing

      blueprint = create!(digest)
      notify(blueprint)

      Result.new(blueprint:, created: true)
    end

    private

    def validate!
      if @files.size > Blueprint.max_files
        raise McpToolError.new(:invalid_input, "files は #{Blueprint.max_files} 件までです")
      end

      total = @dockerfile.bytesize + @files.sum { |file| file[:content].to_s.bytesize }
      return if total <= Blueprint.max_context_bytes

      raise McpToolError.new(:context_too_large,
        "context が大きすぎます: #{total} バイト（上限 #{Blueprint.max_context_bytes}）")
    end

    # A proposal sits in pending_review until a human looks at it, and nothing
    # else tells them it arrived. Only for new ones: proposing the same content
    # again returns the existing row and is not news.
    def notify(blueprint)
      PushNotificationJob.perform_later(
        title: "実行環境のレビュー待ち",
        body: "#{blueprint.name} — #{blueprint.summary}",
        path: "/admin/blueprints/#{blueprint.id}"
      )
    end

    def create!(digest)
      Blueprint.create!(
        # Chained to the previous revision under the same name, which is what lets
        # /admin review it as a diff
        parent: Blueprint.where(name: @name).order(created_at: :desc).first,
        name: @name,
        summary: @summary,
        dockerfile: @dockerfile,
        digest:,
        state: :pending_review,
        created_by: @user,
        oauth_application: @oauth_application,
        blueprint_files_attributes: @files.map do |file|
          { path: file[:path], content: file[:content], executable: !!file[:executable] }
        end
      )
    rescue ActiveRecord::RecordInvalid => e
      raise McpToolError.new(:invalid_input, e.record.errors.full_messages.join(", "))
    end
  end
end
