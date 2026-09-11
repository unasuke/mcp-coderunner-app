class User < ApplicationRecord
  # Stored as strings: it reads as something when looking straight at the database,
  # and reordering the values breaks nothing
  enum :role, { pending: "pending", member: "member", admin: "admin" }, default: "pending"

  has_many :sessions, dependent: :destroy
  belongs_to :approved_by, class_name: "User", optional: true

  validates :github_uid, presence: true, uniqueness: true
  validates :login, presence: true

  # A pending user can do nothing at all. MCP is reachable from member and above
  def can_use_mcp?
    member? || admin?
  end

  def approve!(by:, role: :member)
    update!(role:, approved_by: by, approved_at: Time.current)
    return if can_use_mcp?

    # Taking access away cuts the MCP tokens, not only the browser sessions.
    # A promotion touches neither
    sessions.destroy_all
    revoke_oauth_access!
  end

  def revoke_oauth_access!
    Doorkeeper::AccessToken.where(resource_owner_id: id, revoked_at: nil).find_each(&:revoke)
    Doorkeeper::AccessGrant.where(resource_owner_id: id, revoked_at: nil).find_each(&:revoke)
  end
end
