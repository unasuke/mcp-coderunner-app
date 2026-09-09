module McpTools
  class GetJob < Base
    tool_name "get_job"
    description "ジョブの状態と結果。applied_limits を必ず含むので、ベンチマークの数値は制限下のものだと分かる。"

    input_schema(
      properties: { job_id: { type: "integer" } },
      required: [ "job_id" ]
    )

    def self.call(job_id:, server_context: nil)
      guard do
        job = Job.find_by(id: job_id) ||
          raise(McpToolError.new(:job_not_found, "ジョブが見つかりません: #{job_id}"))

        respond(payload_for(job))
      end
    end

    def self.payload_for(job)
      payload = { job_id: job.id, state: job.state, profile: job.profile,
                  blueprint_digest: job.blueprint.digest }
      payload[:review_url] = review_url("/admin/jobs/#{job.id}") if job.pending_review?
      # 保持期間を過ぎたことが応答から読めれば、結果が空なのを実行の失敗と誤読しない
      return payload.merge(purged_at: job.purged_at.utc.iso8601) if job.purged?

      result = job.job_result
      return payload unless result

      payload.merge(
        termination_reason: result.termination_reason,
        exit_code: result.exit_code,
        stdout: result.stdout,
        stderr: result.stderr,
        truncated: result.truncated,
        duration_ms: result.duration_ms,
        cpu_time_ms: result.cpu_time_ms,
        max_rss_bytes: result.max_rss_bytes,
        applied_limits: result.applied_limits
      )
    end
  end
end
