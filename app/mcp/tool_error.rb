# ツールのエラーは JSON-RPC のエラーではなく、isError を立てた結果として本文で返す。
# プロトコルレベルのエラーにすると、クライアントによっては内容がモデルに届かず、
# 何が悪かったか分からないまま同じ呼び出しを繰り返すことになる。
module Mcp
  class ToolError < StandardError
    CODES = %w[
      blueprint_not_found
      not_approved
      script_too_large
      context_too_large
      job_not_found
      invalid_profile
      invalid_input
    ].freeze

    attr_reader :code, :details

    def initialize(code, message, **details)
      raise ArgumentError, "unknown code: #{code}" unless CODES.include?(code.to_s)

      @code = code.to_s
      @details = details
      super(message)
    end

    def to_h
      { error: code, message: message }.merge(details)
    end
  end
end
