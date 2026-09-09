class Job < ApplicationRecord
  STATES = %w[ pending_review rejected queued leased running finished ].freeze
  # 検証用のスクリプトは普通は数 KB に収まる。これを超えている時点で何か変なことが起きている
  REVIEW_SCRIPT_BYTES = 64 * 1024
  MAX_SCRIPT_BYTES = 256 * 1024

  # 既定値は pending_review。state の設定を書き忘れたジョブは実行されずに止まる
  enum :state, STATES.index_by(&:itself), default: "pending_review"

  belongs_to :blueprint
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :approved_by, class_name: "User", optional: true
  belongs_to :oauth_application, class_name: "Doorkeeper::Application", optional: true

  has_many :leases, dependent: :destroy
  has_one :job_result, dependent: :destroy

  validates :script, length: { maximum: MAX_SCRIPT_BYTES }
  validates :profile, inclusion: { in: Protocol::ResourceProfile::NAMES }

  scope :claimable, -> { queued.order(:created_at) }

  # 試行回数のカラムは持たない。leases の本数がそのまま試行回数になる
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

  # pending_review には承認と却下だけを置き、queued 以降にはキャンセルだけを置く
  def approvable?
    pending_review?
  end

  def cancellable?
    queued? || leased? || running?
  end

  def cancel_requested?
    cancel_requested_at.present?
  end

  def approve!(by:)
    update!(state: :queued, approved_by: by)
  end

  def reject!(by:)
    update!(state: :rejected, approved_by: by)
  end

  def finish_with!(attributes)
    transaction do
      create_job_result!(attributes)
      update!(state: :finished)
    end
  end
end
