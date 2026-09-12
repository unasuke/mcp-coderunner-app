module Blueprints
  # Rejecting and revoking both leave jobs that can never run. A job is only
  # approvable while its Blueprint is approved, so anything sitting in
  # pending_review afterwards is waiting for an answer that will never come --
  # nobody can give it, and the MCP side will not take a new job on that digest
  # either. Reject them along with it rather than leaving a row that can only be
  # tidied by hand.
  #
  # Queued jobs are left alone. Revoking stops new submissions and lets what is
  # already in the queue run (design 11), and that is unchanged: this only reaches
  # jobs that never got past review.
  class Withdraw
    def self.reject(blueprint:, by:, note: nil)
      apply(blueprint:, by:) { blueprint.reject!(by:, note:) }
    end

    def self.revoke(blueprint:, by:, note: nil)
      apply(blueprint:, by:) { blueprint.revoke!(by:, note:) }
    end

    # Returns the jobs it rejected, so the caller can say how many
    def self.apply(blueprint:, by:)
      Blueprint.transaction do
        yield

        blueprint.jobs.pending_review.to_a.each { |job| job.reject!(by:) }
      end
    end
    private_class_method :apply
  end
end
