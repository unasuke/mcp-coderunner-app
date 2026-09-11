class JobResult < ApplicationRecord
  # The list lives in lib/protocol/job_result.rb, and the worker reads the same one
  REASONS = Protocol::JobResult::REASONS

  belongs_to :job

  enum :termination_reason, REASONS.index_by(&:itself)

  # An empty hash is fine: where no container ran (image_build_failed and the
  # like) there are no applied values. Only null is kept out, by the database's
  # not null
  validates :applied_limits, exclusion: { in: [ nil ] }

  def succeeded?
    exited? && exit_code&.zero?
  end
end
