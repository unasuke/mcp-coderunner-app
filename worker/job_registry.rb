# frozen_string_literal: true

require "protocol/resource_profile"

module Worker
  # 実行中のジョブの台帳。どのスレッドから触っても同じ答えを返す。
  #
  # bench の排他はサーバーとワーカーの両方で持つ。サーバー側だけに置くと、
  # VPS の状態がずれたときに 2 本同時に走り、測定値が静かに壊れる。
  class JobRegistry
    # 実行中のジョブ 1 件。フラグはスレッドをまたいで読む
    class Entry
      attr_reader :payload
      attr_accessor :thread

      def initialize(payload)
        @payload = payload
        @cancelled = false
        @beating = true
      end

      def job_id = payload.job_id
      def lease_id = payload.lease_id

      def cancel! = @cancelled = true
      def cancelled? = @cancelled
      def stop_heartbeat! = @beating = false
      def beating? = @beating

      def exclusive?
        Protocol::ResourceProfile.exist?(payload.profile) &&
          Protocol::ResourceProfile.exclusive?(payload.profile)
      end
    end

    def initialize(max_concurrency:)
      @max_concurrency = max_concurrency
      @entries = {}
      @mutex = Mutex.new
    end

    # 受け入れたら Entry、断ったら nil。
    # 同じ job_id が走っているときは断る。サーバー側は保持中のリースを 1 本に
    # 保証しているが、ワーカーは VPS を信用しないので実行中の行を上書きしない。
    def add(payload)
      @mutex.synchronize do
        return nil if @entries.size >= @max_concurrency
        return nil if @entries.values.any? { |entry| entry.job_id == payload.job_id }

        @entries[payload.lease_id] = Entry.new(payload)
      end
    end

    def delete(lease_id)
      @mutex.synchronize { @entries.delete(lease_id) }
    end

    def entries
      @mutex.synchronize { @entries.values }
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    def empty?
      size.zero?
    end

    # 排他ジョブを抱えているあいだは新しい lease を取らない（max_concurrency を無視する）
    def busy?
      @mutex.synchronize do
        @entries.size >= @max_concurrency || @entries.values.any?(&:exclusive?)
      end
    end

    # 排他ジョブが走り出してよいか。自分以外が捌けるまで待つ
    def alone?(entry)
      @mutex.synchronize { @entries.values.all? { |other| other.equal?(entry) } }
    end

    def cancel_all!
      entries.each(&:cancel!)
    end
  end
end
