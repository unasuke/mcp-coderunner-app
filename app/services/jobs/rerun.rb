module Jobs
  # Runs a job again: the same script, on the same Blueprint digest, with the same
  # profile and entrypoint.
  #
  # It submits a new job rather than resetting the old one. A job carries one
  # result and the leases it took, and putting it back to queued would overwrite
  # both -- the record of what happened the first time is the reason to re-run at
  # all. The new row points at the old one through retried_from.
  #
  # Submitting is the only way in, so nothing here is a way around review: the
  # digest is the one that was approved, and bench or an outsized script still
  # stops for a human. The disk having filled up is not a reason to skip that.
  class Rerun
    # nil when the job is not something that can be run again, the same shape
    # Cancel answers in. The Blueprint being withdrawn since raises out of Submit
    def self.call(job:, user:)
      return nil unless job.rerunnable?

      Submit.call(
        blueprint_ref: job.blueprint.digest,
        script: job.script,
        profile: job.profile,
        entrypoint: job.entrypoint,
        user:,
        retried_from: job
      )
    end
  end
end
