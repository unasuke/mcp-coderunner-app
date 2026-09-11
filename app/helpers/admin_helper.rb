module AdminHelper
  # A state is shown as a word and a color, and the color comes from the meaning:
  # pine for approved and healthy, ochre for waiting on a person, iron-rust for
  # failed and withdrawn, indigo for in flight
  TONES = {
    "approved" => "go", "member" => "go", "admin" => "go", "exited" => "go",
    "pending_review" => "wait", "pending" => "wait",
    "rejected" => "stop", "revoked" => "stop", "timeout" => "stop",
    "oom_killed" => "stop", "pids_exceeded" => "stop", "disk_full" => "stop",
    "image_build_failed" => "stop", "policy_rejected" => "stop",
    "worker_error" => "stop", "lease_expired" => "stop", "cancelled" => "stop",
    "queued" => "live", "leased" => "live", "running" => "live",
    "finished" => "mute"
  }.freeze

  def state_tag(value, tone: nil)
    return tag.span("—", class: "dim") if value.blank?

    tag.span(value, class: "state state-#{tone || TONES.fetch(value.to_s, 'mute')}")
  end

  # Ran to completion, but a non-zero exit_code still reads as a failure
  def outcome_tag(result)
    return tag.span("—", class: "dim") unless result

    tone = result.exited? && !result.exit_code&.zero? ? "stop" : nil
    state_tag(result.termination_reason, tone:)
  end

  def since(time)
    return tag.span("—", class: "dim") unless time

    tag.time(relative_time(time), datetime: time.iso8601, title: time.strftime("%Y-%m-%d %H:%M:%S"))
  end

  # Avoids pulling in rails-i18n. A time in the future (a lease's expiry) reads the same way
  def relative_time(time, now = Time.current)
    seconds = (now - time).round
    suffix = seconds.negative? ? "後" : "前"

    case seconds.abs
    when 0...60 then "たった今"
    when 60...3600 then "#{seconds.abs / 60} 分#{suffix}"
    when 3600...86_400 then "#{seconds.abs / 3600} 時間#{suffix}"
    else "#{seconds.abs / 86_400} 日#{suffix}"
    end
  end

  def short(value, length = 12)
    return tag.span("—", class: "dim") if value.blank?

    tag.span(value.to_s.first(length), class: "mono", title: value)
  end

  # A button says what pressing it does
  def role_action_label(role)
    { "pending" => "承認待ちに戻す", "member" => "member にする", "admin" => "admin にする" }.fetch(role, role)
  end

  # Only shorten what looks like a revision, so "development" does not read "developm"
  def commit_label(value)
    return tag.span("—", class: "dim") if value.blank?

    value.match?(/\A[0-9a-f]{12,}\z/) ? short(value, 8) : tag.span(value, class: "mono")
  end

  def bytes(value)
    return tag.span("—", class: "dim") unless value

    number_to_human_size(value)
  end

  # Whether a worker is alive, shown in the top bar. It is behind most cases of a
  # job sitting in queued
  def worker_pulse
    process = WorkerProcess.alive.order(:last_heartbeat_at).last
    return state_tag("ワーカー不在", tone: "stop") unless process

    tag.span("ワーカー #{process.worker_id} #{process.busy}/#{process.capacity}", class: "state state-go")
  end
end
