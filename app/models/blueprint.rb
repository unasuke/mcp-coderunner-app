class Blueprint < ApplicationRecord
  InvalidTransition = Class.new(StandardError)

  # There is no draft. propose_blueprint is the only way a Blueprint comes into
  # being, and it is waiting for review from the moment it is proposed
  STATES = %w[ pending_review approved rejected revoked ].freeze
  NAME_FORMAT = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

  def self.max_dockerfile_bytes = Rails.configuration.x.mcp_coderunner_app.dockerfile_max_bytes
  def self.max_context_bytes = Rails.configuration.x.mcp_coderunner_app.context_max_bytes
  def self.max_files = Rails.configuration.x.mcp_coderunner_app.max_context_files
  def self.list_limit = Rails.configuration.x.mcp_coderunner_app.blueprint_list_limit

  enum :state, STATES.index_by(&:itself), default: "pending_review"

  has_many :blueprint_files, -> { order(:path) }, dependent: :destroy, inverse_of: :blueprint
  has_many :jobs, dependent: :restrict_with_exception
  has_many :revisions, class_name: "Blueprint", foreign_key: :parent_id, dependent: :nullify,
    inverse_of: :parent

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  belongs_to :parent, class_name: "Blueprint", optional: true
  belongs_to :oauth_application, class_name: "Doorkeeper::Application", optional: true

  validates :name, presence: true, format: { with: NAME_FORMAT }
  validates :summary, presence: true, length: { maximum: 200 }
  validates :dockerfile, presence: true, length: { maximum: ->(_) { max_dockerfile_bytes } }
  validates :digest, presence: true, uniqueness: true

  accepts_nested_attributes_for :blueprint_files

  # name is not unique. Every revision makes another record chained by parent_id,
  # so rows sharing a name are expected
  scope :latest_approved, ->(name) { approved.where(name:).order(created_at: :desc) }

  def self.digest_for(dockerfile:, files:)
    Protocol::BlueprintDigest.compute(dockerfile:, files:)
  end

  def compute_digest
    self.class.digest_for(
      dockerfile: dockerfile,
      files: blueprint_files.map { |file| { path: file.path, content: file.content, executable: file.executable } }
    )
  end

  # Transitions are closed on the server. POSTing at something revoked will not
  # walk it back to approved
  def reviewable?
    pending_review?
  end

  def revocable?
    approved?
  end

  def approve!(by:)
    raise InvalidTransition, "blueprint is #{state}" unless reviewable?

    update!(state: :approved, reviewed_by: by, reviewed_at: Time.current)
  end

  def reject!(by:, note: nil)
    raise InvalidTransition, "blueprint is #{state}" unless reviewable?

    update!(state: :rejected, reviewed_by: by, reviewed_at: Time.current, review_note: note)
  end

  # Revoking stops new submissions only. A job already queued still runs
  def revoke!(by:, note: nil)
    raise InvalidTransition, "blueprint is #{state}" unless revocable?

    update!(state: :revoked, reviewed_by: by, reviewed_at: Time.current, review_note: note)
  end

  # What happened the last time anything ran on this environment. The MCP tools
  # hand it back so a client can tell "my script was wrong" from "this environment
  # cannot be built", which otherwise look the same from the outside.
  def last_job_result
    self.class.last_job_results_for([ self ])[id]
  end

  # Same thing for a list, in one query rather than one per row. Both tables carry a
  # created_at, so the order has to say which one it means. Ordered oldest first,
  # index_by keeps the last write per blueprint -- the newest result.
  def self.last_job_results_for(blueprints)
    ids = Array(blueprints).map(&:id)
    return {} if ids.empty?

    JobResult.joins(:job)
      .where(jobs: { blueprint_id: ids })
      .order("job_results.created_at ASC")
      .select("job_results.*", "jobs.blueprint_id AS blueprint_id")
      .index_by(&:blueprint_id)
  end

  def context_bytes
    dockerfile.bytesize + blueprint_files.sum { |file| file.content.bytesize }
  end

  def to_lease_payload
    {
      "digest" => digest,
      "dockerfile" => dockerfile,
      "files" => blueprint_files.map do |file|
        { "path" => file.path, "content" => file.content, "executable" => file.executable }
      end
    }
  end
end
