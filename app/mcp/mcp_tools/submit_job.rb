module McpTools
  class SubmitJob < Base
    tool_name "submit_job"
    description <<~TEXT
      承認済みの Blueprint 上でスクリプトを実行する。すぐには返らず、job_id を返す。
      結果は get_job で取りに行く。

      コンテナは隔離されている。ネットワークには出られない（DNS も引けない）。
      ファイルシステムは読み取り専用で、**書き込めるのは /tmp だけ**（tmpfs）。
      カレントディレクトリ（/work）に書き出す処理は EROFS で失敗するので、
      出力先は /tmp にすること。
    TEXT

    input_schema(
      properties: {
        blueprint: { type: "string", description: "digest（64 桁の hex）か name。name なら同名で最新の承認済みを使う" },
        script: { type: "string",
                  description: "コンテナ内の /work/script.rb に置かれる本体。/work は読み取り専用で、書き込みは /tmp へ" },
        profile: {
          type: "string",
          enum: Protocol::ResourceProfile::NAMES,
          description: "default は 2GB/2cpu/60 秒。bench は 4GB/4cpu/300 秒で承認が要る"
        },
        entrypoint: {
          type: "array",
          items: { type: "string" },
          description: "省略時は [\"ruby\", \"/work/script.rb\"]"
        }
      },
      required: [ "blueprint", "script" ]
    )

    def self.call(blueprint:, script:, profile: Protocol::ResourceProfile::DEFAULT, entrypoint: nil,
                  server_context: nil)
      guard do
        job = Jobs::Submit.call(
          blueprint_ref: blueprint, script:, profile:, entrypoint:,
          user: Current.user, oauth_application: Current.oauth_application
        )

        payload = {
          job_id: job.id,
          state: job.state,
          blueprint_digest: job.blueprint.digest,
          profile: job.profile
        }
        payload[:review_url] = review_url("/admin/jobs/#{job.id}") if job.pending_review?

        respond(payload)
      end
    end
  end
end
