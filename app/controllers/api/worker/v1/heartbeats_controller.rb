module Api
  module Worker
    module V1
      class HeartbeatsController < BaseController
        # 30 秒ごと。ジョブの有無にかかわらず打つ。
        # busy はワーカーに申告させない。サーバーが未解放の leases を数える
        def create
          process = find_process
          return render(json: { error: "unknown instance" }, status: :not_found) unless process

          process.beat!

          render json: {
            server_commit: server_commit,
            outdated: outdated?,
            # プロトコル不一致のときは新規の lease を止めさせる
            drain: !protocol_matches?
          }
        end
      end
    end
  end
end
