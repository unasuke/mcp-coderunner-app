# frozen_string_literal: true

module Protocol
  # 名前付きのリソースプロファイル。数値を自由に指定させず、ここにある組み合わせだけを許す。
  # Rails 側は submit_job の検証と lease で送る具体値に、ワーカー側は clamp の入力に使う。
  module ResourceProfile
    ALL = {
      "default" => {
        memory_mb: 2048, cpus: 2, pids: 512, timeout_s: 60, tmpfs_mb: 512,
        exclusive: false, requires_approval: false
      },
      "bench" => {
        memory_mb: 4096, cpus: 4, pids: 1024, timeout_s: 300, tmpfs_mb: 1024,
        exclusive: true, requires_approval: true
      }
    }.freeze

    NAMES = ALL.keys.freeze

    DEFAULT = "default"

    # lease で送る limits。exclusive / requires_approval はサーバー側の判断材料なので含めない
    LIMIT_KEYS = %i[ memory_mb cpus pids timeout_s tmpfs_mb ].freeze

    def self.exist?(name)
      ALL.key?(name)
    end

    def self.fetch(name)
      ALL.fetch(name) { raise KeyError, "unknown profile: #{name.inspect}" }
    end

    def self.limits_for(name)
      fetch(name).slice(*LIMIT_KEYS)
    end

    def self.exclusive?(name)
      fetch(name).fetch(:exclusive)
    end

    def self.requires_approval?(name)
      fetch(name).fetch(:requires_approval)
    end
  end
end
