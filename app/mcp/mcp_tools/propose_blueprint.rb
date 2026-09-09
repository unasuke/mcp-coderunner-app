module McpTools
  class ProposeBlueprint < Base
    tool_name "propose_blueprint"
    description <<~TEXT
      新しい実行環境（Dockerfile と context ファイル）を提案する。人間のレビューを通ってから使える。
      同じ内容が既にあれば、新しく作らずその状態を返す。
    TEXT

    input_schema(
      properties: {
        name: { type: "string", description: "英小文字・数字・. _ - のみ、64 文字まで" },
        summary: { type: "string", description: "用途の 1 行説明。レビューする人間が最初に読む" },
        dockerfile: { type: "string" },
        files: {
          type: "array",
          description: "build context に置くファイル（Gemfile など）",
          items: {
            type: "object",
            properties: {
              path: { type: "string" },
              content: { type: "string" },
              executable: { type: "boolean" }
            },
            required: [ "path", "content" ]
          }
        }
      },
      required: [ "name", "summary", "dockerfile" ]
    )

    def self.call(name:, summary:, dockerfile:, files: [], server_context: nil)
      guard do
        result = Blueprints::Propose.call(
          name:, summary:, dockerfile:, files: files.map(&:to_h),
          user: Current.user, oauth_application: Current.oauth_application
        )
        blueprint = result.blueprint

        respond({
          blueprint_id: blueprint.id,
          name: blueprint.name,
          digest: blueprint.digest,
          state: blueprint.state,
          created: result.created,
          review_note: blueprint.review_note,
          review_url: review_url("/admin/blueprints/#{blueprint.id}")
        })
      end
    end
  end
end
