# frozen_string_literal: true

require "protocol/resource_profile"

module Worker
  # The ledger of jobs in flight. It answers the same from any thread.
  #
  # Exclusivity for bench is held on both the server and the worker. On the server
  # alone, a VPS whose state has drifted would let two run at once and quietly
  # ruin the measurement.
  class JobRegistry
    # One job in flight. Its flags are read from other threads
    class Entry
      attr_reader :payload
      attr_accessor :thread

      def initialize(payload)
        @payload = payload
        @cancelled = false
        @cancel_reason = nil
        @beating = true
      end

      def job_id = payload.job_id
      def lease_id = payload.lease_id

      # Why it was cancelled decides what happens to the job. An admin asking for it
      # wants the job finished as cancelled; the worker shutting down wants the job
      # back in the queue, so it holds the lease and lets /deregister requeue it.
      # The first reason wins: someone who cancelled before the shutdown still gets
      # the answer they asked for.
      def cancel!(reason = :requested)
        @cancel_reason ||= reason
        @cancelled = true
      end

      def cancelled? = @cancelled
      def shutdown? = @cancel_reason == :shutdown
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

    # An Entry when accepted, nil when turned away.
    # A job_id already running is turned away. The server guarantees only one lease
    # is held at a time, but the worker does not take the VPS at its word and will
    # not overwrite a row that is running.
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

    # While an exclusive job is held, take no new lease regardless of max_concurrency
    def busy?
      @mutex.synchronize do
        @entries.size >= @max_concurrency || @entries.values.any?(&:exclusive?)
      end
    end

    # Whether an exclusive job may start. It waits until everything else has drained
    def alone?(entry)
      @mutex.synchronize { @entries.values.all? { |other| other.equal?(entry) } }
    end

    def cancel_all!
      entries.each(&:cancel!)
    end
  end
end
