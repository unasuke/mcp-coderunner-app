module McpTools
  class ListBlueprints < Base
    tool_name "list_blueprints"
    description "承認済みの実行環境（Blueprint）の一覧。submit_job にはここで得た digest か name を渡す。"

    input_schema(properties: {}, required: [])

    def self.call(server_context: nil)
      guard do
        blueprints = Blueprint.approved.order(created_at: :desc).limit(Blueprint.list_limit)

        respond({ blueprints: blueprints.map { |blueprint|
          {
            blueprint_id: blueprint.id,
            name: blueprint.name,
            digest: blueprint.digest,
            summary: blueprint.summary,
            created_at: blueprint.created_at.utc.iso8601
          }
        } })
      end
    end
  end
end
