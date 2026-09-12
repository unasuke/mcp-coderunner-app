module McpTools
  class ListBlueprints < Base
    tool_name "list_blueprints"
    description <<~TEXT
      承認済みの実行環境（Blueprint）の一覧。submit_job にはここで得た digest か name を渡す。

      last_result は、その実行環境で最後に走ったジョブの結果。承認時にビルド確認のジョブが
      自動で投入されるので、通常はその結果になる。ここが image_build_failed なら
      **実行環境自体がビルドできない**ので、スクリプトを直しても直らない。
    TEXT

    input_schema(properties: {}, required: [])

    def self.call(server_context: nil)
      guard do
        blueprints = Blueprint.approved.order(created_at: :desc).limit(Blueprint.list_limit)
        results = Blueprint.last_job_results_for(blueprints)

        respond({ blueprints: blueprints.map { |blueprint|
          {
            blueprint_id: blueprint.id,
            name: blueprint.name,
            digest: blueprint.digest,
            summary: blueprint.summary,
            created_at: blueprint.created_at.utc.iso8601,
            last_result: last_result_for(results[blueprint.id])
          }
        } })
      end
    end
  end
end
