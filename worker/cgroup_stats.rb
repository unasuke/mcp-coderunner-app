# frozen_string_literal: true

module Worker
  # Reads statistics for a running container out of the cgroup.
  #
  # The cgroup directory goes away with the container, so the numbers have to be
  # taken while it is still running. docker inspect reports neither cpu time nor rss.
  #
  # Every read is best-effort. Missing file, no permission, container already gone:
  # each returns nil and the job still succeeds. Failing to measure a run is not
  # the same as the run failing.
  class CgroupStats
    INTERVAL = 1.0
    CGROUP_ROOT = "/sys/fs/cgroup"

    attr_reader :cpu_time_ms, :max_rss_bytes, :oom_kills, :pids_max_events

    def initialize(pid, interval: INTERVAL, cgroup_root: CGROUP_ROOT, base: nil)
      @pid = pid
      @interval = interval
      @base = base || self.class.resolve_base(pid, cgroup_root:)
      @oom_kills = 0
      @pids_max_events = 0
      @mutex = Mutex.new
      @stopping = false
    end

    # Under cgroup v2, /proc/<pid>/cgroup is a single line like
    # "0::/system.slice/docker-<id>.scope". The shape of the directory depends on
    # the cgroup driver (systemd or cgroupfs), so read the path from /proc rather
    # than assembling it.
    def self.resolve_base(pid, cgroup_root: CGROUP_ROOT)
      line = File.read("/proc/#{pid}/cgroup").lines.find { |l| l.start_with?("0::") }
      return nil unless line

      File.join(cgroup_root, line.split("::", 2).last.strip)
    rescue SystemCallError
      nil
    end

    def start
      return self unless @base

      @thread = Thread.new do
        until @stopping
          sample
          sleep @interval
        end
      end
      self
    end

    def stop
      @stopping = true
      @thread&.join(@interval * 2)
      sample
      self
    end

    # Does nothing when the cgroup path was never resolved -- the container ended
    # first and left /proc, or there was no permission to look. Failing to measure
    # a run is not the same as the run failing
    def sample
      return self unless @base

      @mutex.synchronize do
        read_cpu_time
        read_memory
        read_events
      end
      self
    end

    private

    def read_cpu_time
      usec = keyed_value(read_file("cpu.stat"), "usage_usec")
      @cpu_time_ms = usec / 1000 if usec
    end

    # On a kernel without memory.peak, stand in the highest memory.current seen while polling
    def read_memory
      peak = read_file("memory.peak")&.strip&.to_i
      current = read_file("memory.current")&.strip&.to_i
      candidate = peak && peak.positive? ? peak : current
      return unless candidate

      @max_rss_bytes = [ @max_rss_bytes.to_i, candidate ].max
    end

    # When only a child process is OOM-killed the container as a whole survives,
    # so State.OOMKilled reads false. Without looking here, that gets misread.
    def read_events
      oom = keyed_value(read_file("memory.events"), "oom_kill")
      @oom_kills = [ @oom_kills, oom ].max if oom

      pids_max = keyed_value(read_file("pids.events"), "max")
      @pids_max_events = [ @pids_max_events, pids_max ].max if pids_max
    end

    def read_file(name)
      File.read(File.join(@base, name))
    rescue SystemCallError
      nil
    end

    def keyed_value(content, key)
      return nil unless content

      line = content.lines.find { |l| l.start_with?("#{key} ") }
      line&.split(/\s+/)&.last&.to_i
    end
  end
end
