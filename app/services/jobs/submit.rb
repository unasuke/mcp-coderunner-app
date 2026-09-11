module Jobs
  # Submits a job. It does not wait for the run.
  #
  # On an approved Blueprint the job starts queued. Any of the following puts it
  # in pending_review instead:
  #   - the Blueprint is not approved
  #   - the profile is something other than default
  #   - the script is over 64KB
  class Submit
    DIGEST_FORMAT = /\A[0-9a-f]{64}\z/

    def self.call(...) = new(...).call

    def initialize(blueprint_ref:, script:, profile: Protocol::ResourceProfile::DEFAULT,
                   entrypoint: nil, user: nil, oauth_application: nil)
      @blueprint_ref = blueprint_ref.to_s
      @script = script.to_s
      @profile = (profile.presence || Protocol::ResourceProfile::DEFAULT).to_s
      @entrypoint = entrypoint
      @user = user
      @oauth_application = oauth_application
    end

    def call
      validate!
      blueprint = resolve_blueprint
      reject_withdrawn!(blueprint)

      Job.create!(
        blueprint:,
        script: @script,
        profile: @profile,
        entrypoint: @entrypoint.presence,
        state: review_needed?(blueprint) ? :pending_review : :queued,
        requested_by: @user,
        oauth_application: @oauth_application
      )
    end

    private

    def validate!
      unless Protocol::ResourceProfile.exist?(@profile)
        raise McpToolError.new(:invalid_profile, "知らない profile です: #{@profile}")
      end

      return if @script.bytesize <= Job.max_script_bytes

      raise McpToolError.new(:script_too_large,
        "script が大きすぎます: #{@script.bytesize} バイト（上限 #{Job.max_script_bytes}）")
    end

    # Content a human has turned down cannot be submitted again by anyone holding
    # the digest. Revoking stops new submissions, so what is already queued is
    # left alone
    def reject_withdrawn!(blueprint)
      return unless blueprint.rejected? || blueprint.revoked?

      raise McpToolError.new(:not_approved,
        "この Blueprint は #{blueprint.state} です: #{blueprint.digest}",
        review_note: blueprint.review_note)
    end

    # A digest is looked up as-is. A name resolves to the newest approved row under it
    def resolve_blueprint
      if @blueprint_ref.match?(DIGEST_FORMAT)
        Blueprint.find_by(digest: @blueprint_ref) ||
          raise(McpToolError.new(:blueprint_not_found, "digest が見つかりません: #{@blueprint_ref}"))
      else
        Blueprint.latest_approved(@blueprint_ref).first ||
          raise(McpToolError.new(:not_approved, "承認済みの Blueprint がありません: #{@blueprint_ref}"))
      end
    end

    def review_needed?(blueprint)
      !blueprint.approved? ||
        Protocol::ResourceProfile.requires_approval?(@profile) ||
        @script.bytesize > Job.review_script_bytes
    end
  end
end
