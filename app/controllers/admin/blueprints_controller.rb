module Admin
  class BlueprintsController < BaseController
    before_action :set_blueprint, except: :index

    def index
      @blueprints = Blueprint.order(created_at: :desc).includes(:created_by).limit(200)
    end

    def show
      @parent = @blueprint.parent
    end

    def approve
      @blueprint.approve!(by: current_user)
      redirect_to admin_blueprint_path(@blueprint), notice: "承認しました"
    end

    def reject
      @blueprint.reject!(by: current_user, note: params[:review_note])
      redirect_to admin_blueprint_path(@blueprint), notice: "却下しました"
    end

    # revoked が止めるのは新規投入だけ。既に queued に入っているジョブは走る
    def revoke
      @blueprint.revoke!(by: current_user, note: params[:review_note])
      redirect_to admin_blueprint_path(@blueprint), notice: "失効させました（キューに残っているジョブは実行されます）"
    end

    private

    def set_blueprint
      @blueprint = Blueprint.find(params[:id])
    end
  end
end
