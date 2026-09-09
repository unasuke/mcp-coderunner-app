# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "protocol/constants"
require "protocol/job_payload"
require "worker/errors"

module Worker
  # VPS への HTTP。すべてワーカー発で、/api/worker/v1 配下。
  #
  # スレッドセーフではない。接続を 1 本使い回すので、lease のロングポーリングで
  # 25 秒塞がっているあいだ heartbeat が打てなくなる。bin/worker は用途ごとに
  # 別のインスタンスを持つ。
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

    # ジョブが無ければ nil（204）。protocol_version が合わなければ ProtocolMismatch
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

    # lease が失効していたらサーバーは 409 を返す。二重実行の結果で上書きされるのを防ぐため。
    # 409 を受けたら再送しない。そのジョブは既に別の試行が担当している。
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
        # /lease は最大 LEASE_WAIT 秒返らない。暗黙の既定値に頼ると窓を伸ばしたときに壊れる
        h.read_timeout = Protocol::Constants::LEASE_WAIT + 10
        h.keep_alive_timeout = 30
        h.max_retries = 0
        h.start
      end
    end
  end
end
