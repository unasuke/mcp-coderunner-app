# Sweeps two things every 10 seconds.
#
#   1. worker_processes whose heartbeat has stopped are taken as dead, and every
#      lease that instance held expires at once
#   2. leases past their expiry are collected
#
# The first is what saves waiting out a lease timeout when a worker crashes.
class LeaseReaperJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    reap_stale_processes(now)
    reap_expired_leases(now)
  end

  private

  def reap_stale_processes(now)
    WorkerProcess.stale(now).find_each do |process|
      Lease.active.held_by(process.instance_id).find_each do |lease|
        Jobs::ReleaseLease.call(lease:, reason: "expired")
      end
      process.stop!
    end
  end

  def reap_expired_leases(now)
    Lease.expired(now).find_each do |lease|
      Jobs::ReleaseLease.call(lease:, reason: "expired")
    end
  end
end
