class JobResult < ApplicationRecord
  # 一覧は lib/protocol/job_result.rb にある。ワーカーも同じものを見る
  REASONS = Protocol::JobResult::REASONS

  belongs_to :job

  enum :termination_reason, REASONS.index_by(&:itself)

  # 空のハッシュは許す。コンテナが走っていない終了理由（image_build_failed など）では
  # 適用した値が無い。null だけ DB の not null で防ぐ
  validates :applied_limits, exclusion: { in: [ nil ] }

  def succeeded?
    exited? && exit_code&.zero?
  end
end
