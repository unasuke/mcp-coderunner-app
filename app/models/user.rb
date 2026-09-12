class User < ApplicationRecord
  LastAdmin = Class.new(StandardError)

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

  # Nobody else can approve anything, so demoting this one closes the door from the
  # inside: approving users, Blueprints and jobs all need an admin, and
  # bootstrap_admin_login only ever applies to an account's first sign-in. Getting
  # back in would mean a console on the server.
  def last_admin?
    admin? && self.class.admin.count == 1
  end

  def demotable_to?(role)
    role.to_s == "admin" || !last_admin?
  end

  def approve!(by:, role: :member)
    raise LastAdmin, "#{login} is the only admin" unless demotable_to?(role)

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
