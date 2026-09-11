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
      return redirect_to(admin_blueprint_path(@blueprint), alert: refusal) unless @blueprint.reviewable?

      @blueprint.approve!(by: current_user)
      redirect_to admin_blueprint_path(@blueprint), notice: "承認しました"
    end

    def reject
      return redirect_to(admin_blueprint_path(@blueprint), alert: refusal) unless @blueprint.reviewable?

      @blueprint.reject!(by: current_user, note: params[:review_note])
      redirect_to admin_blueprint_path(@blueprint), notice: "却下しました"
    end

    # Revoking stops new submissions only. A job already queued still runs
    def revoke
      return redirect_to(admin_blueprint_path(@blueprint), alert: refusal) unless @blueprint.revocable?

      @blueprint.revoke!(by: current_user, note: params[:review_note])
      redirect_to admin_blueprint_path(@blueprint), notice: "失効させました（キューに残っているジョブは実行されます）"
    end

    private

    # Something already turned down or revoked cannot be walked back to approved by a POST
    def refusal
      "この実行環境は #{@blueprint.state} です。新しく提案されたものをレビューしてください"
    end

    def set_blueprint
      @blueprint = Blueprint.find(params[:id])
    end
  end
end
