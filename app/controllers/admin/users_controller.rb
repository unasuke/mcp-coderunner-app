module Admin
  class UsersController < BaseController
    def index
      @users = User.order(:created_at)
    end

    # pending の承認と member / admin の昇格。実質 1 人だが、これが無いと 2 人目を通せない
    def update
      user = User.find(params[:id])
      role = params.fetch(:role)
      return redirect_to(admin_users_path, alert: "知らない role です") unless User.roles.key?(role)

      user.approve!(by: current_user, role:)
      redirect_to admin_users_path, notice: "#{user.login} を #{role} にしました"
    end
  end
end
