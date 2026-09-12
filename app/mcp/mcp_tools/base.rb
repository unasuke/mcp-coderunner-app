# What the tools share. One tool per file, under McpTools.
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

      # Returning a review_url is how the model points a human at what to look at
      def review_url(path)
        URI.join(Rails.configuration.x.mcp_coderunner_app.base_url, path).to_s
      end

      # What happened the last time anything ran on an environment. Approving a
      # Blueprint queues a job that builds it, so this is usually that job, and
      # image_build_failed here means the environment itself is broken -- not the
      # script that is about to be submitted.
      def last_result_for(result)
        return nil unless result

        {
          termination_reason: result.termination_reason,
          exit_code: result.exit_code,
          at: result.created_at.utc.iso8601
        }
      end
    end
  end
end
