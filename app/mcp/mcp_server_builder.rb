# MCP::Server（gem 側）を組み立てる。Rails のオートロードでは app/mcp がルートになるので、
# 名前空間ではなく単独の定数として持つ。
#
# トランスポートを SDK に寄せておくと、protocol version のネゴシエーションやセッションの
# 扱いといった、仕様追従が必要で自分では検証しにくい部分を持たずに済む。
module McpServerBuilder
  NAME = "mcprb"
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
