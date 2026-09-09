# frozen_string_literal: true

module Worker
  # 実行中のコンテナの統計を cgroup から採る。
  #
  # コンテナが停止すると cgroup のディレクトリごと消えるので、走っているあいだに
  # 採るしかない。docker inspect には cpu 時間も rss も出ない。
  #
  # 読み取りは全部 best-effort。ファイルが無い、権限が無い、コンテナが先に消えた、
  # のいずれでも nil を返してジョブ自体は成功させる。統計が取れないことは実行の失敗ではない。
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

    # /proc/<pid>/cgroup は cgroup v2 なら "0::/system.slice/docker-<id>.scope" の 1 行。
    # cgroup ドライバ（systemd / cgroupfs）でディレクトリの形が変わるので、
    # パスを組み立てずに /proc から読む。
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

    def sample
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

    # memory.peak が無いカーネルでは memory.current のポーリング最大値で代用する
    def read_memory
      peak = read_file("memory.peak")&.strip&.to_i
      current = read_file("memory.current")&.strip&.to_i
      candidate = peak && peak.positive? ? peak : current
      return unless candidate

      @max_rss_bytes = [ @max_rss_bytes.to_i, candidate ].max
    end

    # 子プロセスだけが OOM で殺された場合、コンテナ全体は生き残るので
    # State.OOMKilled は false になる。ここを見ないと取り違える。
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
