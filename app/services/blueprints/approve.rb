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
    # Not the default `ruby` entrypoint: a Blueprint does not have to be a Ruby
    # image, and asking one that isn't for `ruby` would report a broken environment
    # that is perfectly sound. A shell is the weakest thing there is to ask for, and
    # what it prints identifies the image rather than any language in it.
    #
    # An image with no shell at all (distroless, scratch) fails this. The result says
    # so and nothing is blocked by it -- submitting still works, and a job that names
    # its own entrypoint is unaffected.
    VERIFICATION_SCRIPT = <<~SH
      uname -sm
      cat /etc/os-release 2>/dev/null | head -1
    SH

    VERIFICATION_ENTRYPOINT = [ "sh", "/work/script.rb" ].freeze

    Result = Data.define(:verification_job, :released_jobs)

    def self.call(blueprint:, by:)
      Blueprint.transaction do
        blueprint.approve!(by:)

        Result.new(released_jobs: release_waiting_jobs(blueprint, by),
          verification_job: Jobs::Submit.call(
            blueprint_ref: blueprint.digest,
            script: VERIFICATION_SCRIPT,
            entrypoint: VERIFICATION_ENTRYPOINT,
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
