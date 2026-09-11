# Assembles the gem's MCP::Server. Rails autoloading treats app/mcp as a root, so
# this is a constant of its own rather than a namespace.
#
# Leaving the transport to the SDK means not owning the parts that have to follow
# the specification and are hard to verify here -- protocol version negotiation,
# session handling, and the like.
module McpServerBuilder
  NAME = "mcp-coderunner-app"
  VERSION = "0.1.0"

  TOOLS = [
    McpTools::ListBlueprints,
    McpTools::ProposeBlueprint,
    McpTools::SubmitJob,
    McpTools::GetJob
  ].freeze

  INSTRUCTIONS = <<~TEXT
    任意の Dockerfile 上で Ruby スクリプトを隔離実行する。ベンチマークや Ractor の挙動確認向け。

    実行環境（Blueprint）は人間のレビューを通ったものだけが使える。list_blueprints で承認済みを探し、
    無ければ propose_blueprint で提案する。実行は submit_job で投げて get_job で取りに行く。
    実行コンテナはネットワークに出られない。
  TEXT

  def self.build
    MCP::Server.new(name: NAME, version: VERSION, instructions: INSTRUCTIONS, tools: TOOLS)
  end
end
