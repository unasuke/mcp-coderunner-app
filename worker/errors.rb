# frozen_string_literal: true

module Worker
  Error = Class.new(StandardError)

  # 切り詰められない検証に弾かれた。termination_reason: policy_rejected
  PolicyRejected = Class.new(Error)

  # docker build の失敗。termination_reason: image_build_failed
  BuildFailed = Class.new(Error)

  # docker 自体の失敗やワーカーのバグ。termination_reason: worker_error
  DockerError = Class.new(Error)
end
