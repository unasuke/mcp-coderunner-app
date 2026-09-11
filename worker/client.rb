# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "protocol/constants"
require "protocol/job_payload"
require "worker/errors"

module Worker
  # HTTP to the VPS. Every call starts here, and they all live under /api/worker/v1.
  #
  # Not thread-safe. One connection is reused, so while /lease is holding it for 25
  # seconds no heartbeat can go out. bin/worker keeps a separate instance per use.
  class Client
    ConnectionError = Class.new(Error)
    Unauthorized = Class.new(Error)
    Conflict = Class.new(Error)
    ProtocolMismatch = Class.new(Error)
    ServerError = Class.new(Error)

    RETRYABLE = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::EPIPE,
      EOFError, IOError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
      OpenSSL::SSL::SSLError, SocketError
    ].freeze

    PREFIX = "/api/worker/v1"

    def initialize(policy:, logger: nil)
      @policy = policy
      @logger = logger
      @uri = URI.parse(policy.endpoint)
    end

    def register(instance_id:, commit_hash:, capacity:, hostname:, pid:, ruby_version:, docker_version:)
      post("/register", {
        worker_id: @policy.worker_id,
        instance_id:, commit_hash:, capacity:, hostname:, pid:, ruby_version:, docker_version:,
        protocol_version: Protocol::Constants::PROTOCOL_VERSION
      })
    end

    def heartbeat(instance_id:, commit_hash:)
      post("/heartbeat", {
        instance_id:, commit_hash:,
        protocol_version: Protocol::Constants::PROTOCOL_VERSION
      })
    end

    def deregister(instance_id:, reason:)
      post("/deregister", { instance_id:, reason: })
    end

    # nil when there is no job (204). ProtocolMismatch when protocol_version disagrees
    def lease(instance_id:)
      body = post("/lease", {
        instance_id:,
        protocol_version: Protocol::Constants::PROTOCOL_VERSION
      })
      return nil if body.nil?

      Protocol::JobPayload.from_h(body)
    end

    def job_heartbeat(job_id:, lease_token:)
      post("/jobs/#{job_id}/heartbeat", { lease_token: })
    end

    # The server answers 409 when the lease has expired, which is what keeps the
    # result of a double run from overwriting the real one. Do not resend after a
    # 409: another attempt owns that job now.
    def post_result(job_id:, lease_token:, result:)
      post("/jobs/#{job_id}/result", result.to_h.merge("lease_token" => lease_token))
      true
    rescue Conflict
      false
    end

    def close
      @http&.finish if @http&.started?
    rescue IOError
      nil
    ensure
      @http = nil
    end

    private

    def post(path, payload)
      request = Net::HTTP::Post.new("#{PREFIX}#{path}")
      request["Authorization"] = "Bearer #{@policy.token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(payload)

      handle(http.request(request))
    rescue *RETRYABLE => e
      close
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    def handle(response)
      case response
      when Net::HTTPNoContent then nil
      when Net::HTTPSuccess then response.body.to_s.empty? ? {} : JSON.parse(response.body)
      when Net::HTTPUnauthorized then raise Unauthorized, error_message(response)
      when Net::HTTPConflict then raise conflict_for(response)
      else raise ServerError, "#{response.code}: #{error_message(response)}"
      end
    end

    def conflict_for(response)
      message = error_message(response)
      return ProtocolMismatch.new(message) if message.include?("protocol_version")

      Conflict.new(message)
    end

    def error_message(response)
      body = JSON.parse(response.body.to_s)
      body["error"] || body["message"] || response.body.to_s
    rescue JSON::ParserError
      response.body.to_s
    end

    def http
      @http ||= Net::HTTP.new(@uri.host, @uri.port).tap do |h|
        h.use_ssl = @uri.scheme == "https"
        h.verify_mode = OpenSSL::SSL::VERIFY_PEER
        h.open_timeout = 10
        h.write_timeout = 10
        # /lease can stay silent for LEASE_WAIT seconds. Leaning on the implicit
        # default would break the moment that window grows
        h.read_timeout = Protocol::Constants::LEASE_WAIT + 10
        h.keep_alive_timeout = 30
        h.max_retries = 0
        h.start
      end
    end
  end
end
