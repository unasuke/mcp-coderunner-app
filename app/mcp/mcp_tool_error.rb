# A tool's error comes back in the body with isError set, rather than as a JSON-RPC
# error. Raised at the protocol level, some clients never pass the content to the
# model, which then repeats the same call with no idea what was wrong.
class McpToolError < StandardError
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
