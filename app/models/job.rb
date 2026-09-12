class Job < ApplicationRecord
  NotApprovable = Class.new(StandardError)

  STATES = %w[ pending_review rejected queued leased running finished ].freeze
  # A script written to try something out usually fits in a few KB. Past this, something else is going on
  def self.review_script_bytes = Rails.configuration.x.mcp_coderunner_app.script_review_bytes
  def self.max_script_bytes = Rails.configuration.x.mcp_coderunner_app.script_max_bytes

  # The default is pending_review, so a job whose state nobody set stops rather than runs
  enum :state, STATES.index_by(&:itself), default: "pending_review"

  belongs_to :blueprint
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :oauth_application, class_name: "Doorkeeper::Application", optional: true

  has_many :leases, dependent: :destroy
  has_one :job_result, dependent: :destroy

  validates :script, length: { maximum: ->(_) { max_script_bytes } }
  validates :profile, inclusion: { in: Protocol::ResourceProfile::NAMES }

  scope :claimable, -> { queued.order(:created_at) }

  # No attempt counter column. The number of leases is the number of attempts
  def attempts
    leases.count
  end

  def retriable?
    attempts < Protocol::Constants::MAX_ATTEMPTS
  end

  def active_lease
    leases.active.first
  end

  def entrypoint_or_default
    entrypoint.presence || Protocol::Constants::DEFAULT_ENTRYPOINT
  end

  def limits
    Protocol::ResourceProfile.limits_for(profile)
  end

  def purged?
    purged_at.present?
  end

  # pending_review offers approve and reject, and nothing past queued offers
  # anything but cancel. A job cannot be approved before its Blueprint is, so that
  # no path leads to execution without someone having read the Dockerfile (naming
  # a digest is enough to create a job against an unapproved Blueprint)
  # What makes a job need a human quite apart from its environment: a profile that
  # asks for one, or a script too large to have been written to try something out.
  # An unapproved Blueprint also holds a job back, but that reason can go away on
  # its own -- these two cannot.
  def self.review_required?(profile:, script:)
    Protocol::ResourceProfile.requires_approval?(profile) ||
      script.to_s.bytesize > review_script_bytes
  end

  def review_required_on_its_own?
    self.class.review_required?(profile:, script:)
  end

  def approvable?
    pending_review? && blueprint.approved?
  end

  def cancellable?
    queued? || leased? || running?
  end

  def cancel_requested?
    cancel_requested_at.present?
  end

  def approve!(by:)
    raise NotApprovable, "blueprint #{blueprint.digest} is #{blueprint.state}" unless approvable?

    update!(state: :queued, approved_by: by)
  end

  def reject!(by:)
    raise NotApprovable, "job is #{state}" unless pending_review?

    update!(state: :rejected, approved_by: by)
  end

  def finish_with!(attributes)
    transaction do
      create_job_result!(attributes)
      update!(state: :finished)
    end
  end
end
