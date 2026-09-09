class User < ApplicationRecord
  # 文字列で持つ。DB を直接覗いたときに意味が読め、値の並び替えで壊れない
  enum :role, { pending: "pending", member: "member", admin: "admin" }, default: "pending"

  has_many :sessions, dependent: :destroy
  belongs_to :approved_by, class_name: "User", optional: true

  validates :github_uid, presence: true, uniqueness: true
  validates :login, presence: true

  # pending のユーザーができることは何もない。MCP に到達できるのは member 以上
  def can_use_mcp?
    member? || admin?
  end

  def approve!(by:, role: :member)
    update!(role:, approved_by: by, approved_at: Time.current)
    sessions.destroy_all unless can_use_mcp?
  end
end
