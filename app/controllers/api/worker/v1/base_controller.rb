module Api
  module Worker
    module V1
      # ワーカーのトークンで叩けるのは lease / heartbeat / result のみ。
      # ジョブ投入の口はここに存在しない。投入は MCP エンドポイント経由の一本だけ。
      class BaseController < ActionController::API
        before_action :authenticate_worker!

        attr_reader :current_worker

        private

        def authenticate_worker!
          token = request.authorization.to_s[/\ABearer (.+)\z/, 1]
          @current_worker = ::Worker.authenticate(token)

          render(json: { error: "unauthorized" }, status: :unauthorized) unless @current_worker
        end

        def server_commit
          Rails.configuration.x.mcp_coderunner_app.commit_hash
        end

        # 会話が成立するかどうか。合わなければ lease を止める
        def protocol_matches?
          params[:protocol_version].to_i == Protocol::Constants::PROTOCOL_VERSION
        end

        def outdated?
          params[:commit_hash].present? && params[:commit_hash] != server_commit
        end

        def find_process
          WorkerProcess.find_by(instance_id: params[:instance_id], worker_id: current_worker.worker_id)
        end
      end
    end
  end
end
