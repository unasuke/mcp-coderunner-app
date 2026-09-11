# frozen_string_literal: true

module Worker
  Error = Class.new(StandardError)

  # Refused by the validation that cannot be trimmed into shape. termination_reason: policy_rejected
  PolicyRejected = Class.new(Error)

  # docker build failed. termination_reason: image_build_failed
  BuildFailed = Class.new(Error)

  # docker itself failed, or the worker has a bug. termination_reason: worker_error
  DockerError = Class.new(Error)
end
