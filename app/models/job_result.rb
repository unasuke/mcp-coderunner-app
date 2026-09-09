class JobResult < ApplicationRecord
  # 一覧は lib/protocol/job_result.rb にある。ワーカーも同じものを見る
  REASONS = Protocol::JobResult::REASONS

  belongs_to :job

  enum :termination_reason, REASONS.index_by(&:itself)

  validates :applied_limits, presence: true

  def succeeded?
    exited? && exit_code&.zero?
  end
end
