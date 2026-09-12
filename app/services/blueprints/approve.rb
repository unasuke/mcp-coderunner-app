module Blueprints
  # Approving is also when the environment gets built for the first time.
  #
  # Until now a Dockerfile that cannot be built was only found out by submitting a
  # job and waiting for it to come back as image_build_failed -- a whole round trip
  # spent on something the reviewer could have been told while they were still
  # looking at it. So approval queues a job of its own, and the image is warm by the
  # time a real one arrives (the first job on a new Blueprint is otherwise mostly
  # build time, which is no way to measure anything).
  #
  # The order matters and is not negotiable: approval first, build second. Building
  # before review would mean running an unreviewed Dockerfile with network access,
  # and review is the only thing guarding that phase (design 9.2).
  class Approve
    # Runs under the default entrypoint, so this proves the image builds, starts,
    # and has the ruby the rest of the system assumes. The output is worth keeping
    # around: it says which ruby the environment actually ends up with.
    VERIFICATION_SCRIPT = "puts RUBY_DESCRIPTION\n"

    Result = Data.define(:verification_job, :released_jobs)

    def self.call(blueprint:, by:)
      Blueprint.transaction do
        blueprint.approve!(by:)

        Result.new(released_jobs: release_waiting_jobs(blueprint, by),
          verification_job: Jobs::Submit.call(
            blueprint_ref: blueprint.digest,
            script: VERIFICATION_SCRIPT,
            user: by
          ))
      end
    end

    # A job submitted against a Blueprint nobody had reviewed yet is held back by
    # that and nothing else. Approving is the answer to it, so asking for the job to
    # be approved too would be asking the same question twice -- and the design says
    # a job on an approved digest goes straight through. Jobs that a human owes an
    # answer to for their own sake (bench, an outsized script) stay where they are.
    def self.release_waiting_jobs(blueprint, by)
      blueprint.jobs.pending_review.reject(&:review_required_on_its_own?).each do |job|
        job.approve!(by:)
      end
    end
    private_class_method :release_waiting_jobs
  end
end
