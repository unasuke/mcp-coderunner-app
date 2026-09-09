# ツールの共通部分。1 ツール 1 ファイルで McpTools 以下に置く。
module McpTools
  class Base < MCP::Tool
    class << self
      def respond(payload, error: false)
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error:)
      end

      def guard
        yield
      rescue McpToolError => e
        respond(e.to_h, error: true)
      rescue ActiveRecord::RecordInvalid => e
        respond({ error: "invalid_input", message: e.record.errors.full_messages.join(", ") }, error: true)
      end

      # review_url を返すことで、人間に「ここを見てほしい」と伝えられる
      def review_url(path)
        URI.join(Rails.configuration.x.mcprb.base_url, path).to_s
      end
    end
  end
end
