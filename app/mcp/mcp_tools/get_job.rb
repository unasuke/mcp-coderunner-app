module McpTools
  class GetJob < Base
    tool_name "get_job"

    # How long a call waits for the job to finish, in seconds. Well inside
    # kamal-proxy's response_timeout of 60 and the tool timeouts of MCP clients
    WAIT_S = 25

    # How often the job is looked at while waiting, in seconds. It is one row by
    # primary key, so this can be tighter than /lease's 3: the moment a job
    # finishes is felt directly in the chat
    POLL_INTERVAL_S = 1
    description <<~TEXT
      ジョブの状態と結果。applied_limits を必ず含むので、ベンチマークの数値は制限下のものだと分かる。

      duration_ms は投入から完了までの実時間で、初回はイメージのビルドを含む。
      同じ Blueprint の 2 回目以降はビルドが省かれるので短くなる。
      コンテナ自身の消費を見るなら cpu_time_ms と max_rss_bytes（cgroup から採取）を使う。

      ジョブが終わる（または承認待ちになっている）まで、最大 #{WAIT_S} 秒待ってから返る。
      返ってきた state がまだ queued / leased / running なら、間を空けずにもう一度呼んでよい。
      待たずに今の状態だけを見るなら wait_s: 0。
    TEXT

    input_schema(
      properties: {
        job_id: { type: "integer" },
        wait_s: { type: "integer", description: "終わるまで待つ上限の秒数。0..#{WAIT_S}、省略時は #{WAIT_S}" }
      },
      required: [ "job_id" ]
    )

    def self.call(job_id:, wait_s: WAIT_S, server_context: nil)
      guard do
        job = Job.find_by(id: job_id) ||
          raise(McpToolError.new(:job_not_found, "ジョブが見つかりません: #{job_id}"))

        wait_for_settle(job, wait_s.to_i.clamp(0, WAIT_S))
        respond(payload_for(job))
      end
    end

    # Long polling, in the same plain loop as /lease: SQLite has nothing to be
    # notified by. Waiting is the default so that a model which forgets to ask
    # for it still does not call this over and over while a job runs.
    #
    # pending_review is not waited on. It is waiting for a human, and the
    # review_url is worth more to the caller now than in 25 seconds.
    #
    # Each wait holds a Puma thread. Production has 8, of which the worker's
    # /lease holds one; development's default of 3 leaves one spare.
    def self.wait_for_settle(job, wait_s)
      (wait_s / POLL_INTERVAL_S).times do
        return if settled?(job)

        pause
        job.reload
      end
    end

    def self.settled?(job)
      job.finished? || job.rejected? || job.pending_review?
    end

    # A seam for the tests, which do not sleep
    def self.pause
      sleep POLL_INTERVAL_S
    end

    def self.payload_for(job)
      payload = { job_id: job.id, state: job.state, profile: job.profile,
                  blueprint_digest: job.blueprint.digest }
      payload[:review_url] = review_url("/admin/jobs/#{job.id}") if job.pending_review?
      # With retention visible in the response, an empty result is not misread as a failed run
      payload[:purged_at] = job.purged_at.utc.iso8601 if job.purged?

      result = job.job_result
      return payload unless result

      payload.merge!(
        termination_reason: result.termination_reason,
        exit_code: result.exit_code,
        duration_ms: result.duration_ms,
        cpu_time_ms: result.cpu_time_ms,
        max_rss_bytes: result.max_rss_bytes,
        applied_limits: result.applied_limits
      )

      # The body goes with retention. How the job ended does not
      return payload if job.purged?

      payload.merge(
        stdout: result.stdout,
        stderr: result.stderr,
        truncated: result.truncated
      )
    end
  end
end
