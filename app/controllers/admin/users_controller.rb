module Admin
  class UsersController < BaseController
    def index
      @users = User.order(:created_at)
    end

    # Approving a pending user, and promoting to member or admin. There is one user
    # in practice, but without this there is no way to let a second one in
    def update
      user = User.find(params[:id])
      role = params.fetch(:role)
      return redirect_to(admin_users_path, alert: "知らない role です") unless User.roles.key?(role)

      user.approve!(by: current_user, role:)
      redirect_to admin_users_path, notice: "#{user.login} を #{role} にしました"
    rescue User::LastAdmin
      redirect_to admin_users_path,
        alert: "#{user.login} は最後の admin です。先に別の admin を立ててください"
    end
  end
end
