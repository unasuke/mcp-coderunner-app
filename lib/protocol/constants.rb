# frozen_string_literal: true

module Protocol
  # Rails 側とワーカー側の両方が知っていないと噛み合わなくなる値。
  # 片方だけ変えると壊れるので、1 箇所にしか書かない。
  module Constants
    # lease / result のワイヤーフォーマットを変えたときだけ上げる
    PROTOCOL_VERSION = 1

    # /lease のロングポーリングの窓（秒）。ワーカーの read_timeout はこれより長くする
    LEASE_WAIT = 25

    # worker heartbeat と job heartbeat の間隔（秒）
    HEARTBEAT_INTERVAL = 30

    # /lease のロングポーリングの中で queued を探す間隔（秒）。
    # ここを詰めるほど enqueue から実行開始までが速くなるが、そのぶん
    # 空振りの問い合わせと last_heartbeat_at の更新が増える
    LEASE_POLL_INTERVAL = 3

    # この時間 heartbeat が無い instance は死んだとみなす（秒）。間隔の 4 倍
    HEARTBEAT_EXPIRY = 120

    # lease_expires_at を何秒先に置くか。job heartbeat のたびに更新される
    LEASE_TTL = 120

    # leases の本数がこれ以上になったら再試行しない
    MAX_ATTEMPTS = 2

    # 実行コンテナ内での script の置き場所
    SCRIPT_PATH = "/work/script.rb"

    DEFAULT_ENTRYPOINT = [ "ruby", SCRIPT_PATH ].freeze

    # 孤児コンテナを回収するための目印
    CONTAINER_LABEL = "mcp-coderunner-app.job"

    # ビルドしたイメージのタグ。digest をそのままタグにする
    IMAGE_REPO = "mcp-coderunner-app/bp"

    # /deregister の理由
    DEREGISTER_REASONS = %w[ shutdown update drained ].freeze
  end
end
