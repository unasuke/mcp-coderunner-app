class Blueprint < ApplicationRecord
  # draft は持たない。Blueprint が生まれる経路は propose_blueprint だけで、
  # 提案された時点でレビュー待ちになる
  STATES = %w[ pending_review approved rejected revoked ].freeze
  NAME_FORMAT = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

  def self.max_dockerfile_bytes = Rails.configuration.x.mcprb.dockerfile_max_bytes
  def self.max_context_bytes = Rails.configuration.x.mcprb.context_max_bytes
  def self.max_files = Rails.configuration.x.mcprb.max_context_files
  def self.list_limit = Rails.configuration.x.mcprb.blueprint_list_limit

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

  # name は unique ではない。改訂のたびに parent_id で連なる別レコードができるので、
  # 同じ name の行は複数存在する
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

  def approve!(by:)
    update!(state: :approved, reviewed_by: by, reviewed_at: Time.current)
  end

  def reject!(by:, note: nil)
    update!(state: :rejected, reviewed_by: by, reviewed_at: Time.current, review_note: note)
  end

  # revoked が止めるのは新規投入だけ。既に queued に入っているジョブは走る
  def revoke!(by:, note: nil)
    update!(state: :revoked, reviewed_by: by, reviewed_at: Time.current, review_note: note)
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
