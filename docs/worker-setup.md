# Setting up the worker

*[日本語](worker-setup.ja.md)*

How to get `bin/worker` running on the home VM. **The reasoning behind this shape is in
the design document**, so this file is procedure only. The bar it aims at: that I can
rebuild the VM from it a few months from now.

## Assumptions

- **Ruby 3.3 or newer**, and **rootless** Docker (section 3). Nothing else: no bundler, no synced Gemfile.lock (the worker is written against stdlib alone), and no need to match the Ruby the VPS runs.
  - The distribution's package is what this expects -- the unit runs `/usr/bin/ruby`. A version manager would put the interpreter somewhere a `nologin` system user cannot reach, and would take security updates off apt's hands.
  - 3.3 is the floor because the worker names instances with `SecureRandom.uuid_v7`. On an older Ruby it installs fine and dies at startup.
- Nothing listens on the VM. The worker is outbound only
- No Tailscale on the VM. The boundary is the VM's firewall, in one place

## 1. Issue a token

Enter a `worker_id` (for example `home-vm-01`) at `/admin/workers` on the VPS.
**The plaintext is shown once, right there.** Close the page and it is gone for good;
if you lose it, issue a new one.

## 2. Prepare the VM

```sh
# A home, because the rootless daemon keeps its image store under it. Not in /home:
# nothing of this belongs there, and the image store is state.
sudo useradd --system --create-home --home-dir /var/lib/mcp-coderunner-app \
  --shell /usr/sbin/nologin mcp-coderunner-app

sudo git clone <this repository> /opt/mcp-coderunner-app
cd /opt/mcp-coderunner-app && sudo git rev-parse HEAD | sudo tee /opt/mcp-coderunner-app/REVISION

sudo install -d -m 0755 /etc/mcp-coderunner-app
sudo cp /opt/mcp-coderunner-app/worker/config.example.yml /etc/mcp-coderunner-app/config.yml
sudo $EDITOR /etc/mcp-coderunner-app/config.yml          # fill in worker_id and endpoint

printf '%s' '<the token you were given>' | sudo tee /etc/mcp-coderunner-app/token > /dev/null
sudo chmod 0400 /etc/mcp-coderunner-app/token
sudo chown root:root /etc/mcp-coderunner-app/token
```

Only root can read `/etc/mcp-coderunner-app/token`. systemd hands it to the worker
through `LoadCredential=`, so the `mcp-coderunner-app` user never needs to read the
file itself.

## 3. Rootless Docker

The daemon runs as `mcp-coderunner-app`, not as root. Reaching its socket then means
being that user rather than being root on the VM — which is the whole point, since a
worker that can talk to a rootful daemon is root in all but name.

Two things have to be right or parts of this design quietly stop holding.

```sh
sudo apt install -y uidmap docker-ce-rootless-extras
which dockerd-rootless-setuptool.sh          # comes from that second package

# Subordinate ids. useradd writes these for a normal account and not for a --system
# one, so they have to be added by hand. Any range that overlaps nothing else will
# do, and it has to be at least 65536 wide (the first login user usually holds
# 100000-165535).
cat /etc/subuid /etc/subgid
sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 mcp-coderunner-app
grep ^mcp-coderunner-app: /etc/subuid /etc/subgid   # must not come back empty

# The daemon is a systemd *user* service, so the user manager has to run with nobody logged in
sudo loginctl enable-linger mcp-coderunner-app

# Rootless is delegated memory and pids by default and nothing else. Without cpu,
# --cpus and the cpuset that keeps bench exclusive are accepted and ignored, and the
# worker goes on reporting applied_limits that nothing is applying.
sudo install -d /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
  | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
sudo reboot
```

After the reboot, install the daemon as that user. The account has no login shell, so
hand it the session environment by hand:

```sh
uid=$(id -u mcp-coderunner-app)

# HOME among them: sudo does not set it to the target account's, and the tool
# stops with "HOME needs to be set"
sudo -u mcp-coderunner-app env \
  HOME=/var/lib/mcp-coderunner-app \
  XDG_RUNTIME_DIR=/run/user/$uid \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
  PATH=/usr/bin:/bin \
  dockerd-rootless-setuptool.sh install

sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$uid \
  systemctl --user enable --now docker
```

If the tool refuses to run without a shell, lend the account one for the duration
(`sudo usermod -s /bin/bash mcp-coderunner-app`), install, then put
`/usr/sbin/nologin` back.

Tell the units where the socket is, and take the rootful daemon out of the picture so
nothing reaches it by accident:

```sh
printf 'DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$uid" \
  | sudo tee /etc/mcp-coderunner-app/worker.env

sudo systemctl disable --now docker.service docker.socket
```

### DNS for the build phase

The host resolves through systemd-resolved, whose stub listens on `127.0.0.53`. A
container has its own network namespace and its own loopback, where nothing is
listening, so a build's DNS queries leave and never come back: `apt-get update`
retries each source for twenty seconds at a time and gives up minutes later. The
daemon has no resolver worth passing on, so give it one.

```sh
uid=$(id -u mcp-coderunner-app)

sudo -u mcp-coderunner-app install -d /var/lib/mcp-coderunner-app/.config/docker
sudo -u mcp-coderunner-app tee /var/lib/mcp-coderunner-app/.config/docker/daemon.json > /dev/null <<'JSON'
{ "dns": ["1.1.1.1", "8.8.8.8"] }
JSON

sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$uid systemctl --user restart docker
```

That is the rootless daemon's configuration. `/etc/docker/daemon.json` belongs to the
rootful one and does nothing now.

```sh
printf 'FROM alpine\nRUN cat /etc/resolv.conf && nslookup deb.debian.org\n' > /tmp/df
sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker build --no-cache --progress=plain -f /tmp/df /tmp 2>&1 | tail -20
```

`--progress=plain` matters: without it the output of a `RUN` is not printed. Job
containers never need any of this — they run with `--network none`. Only the build
phase resolves anything.

### Coming from the rootful setup

On a VM that already ran the rootful worker, the account exists and `useradd` above
does nothing — including the home directory, which stays wherever it was created.
The user manager reads the home from `/etc/passwd`, while the setup tool writes its
unit under whatever `HOME` you hand it, and a mismatch ends in
`Unit docker.service not found`.

```sh
sudo usermod --home /var/lib/mcp-coderunner-app mcp-coderunner-app   # no -m: the tool already wrote there
sudo gpasswd -d mcp-coderunner-app docker                            # the unit no longer asks for it
sudo systemctl restart user@$(id -u mcp-coderunner-app).service      # so it rereads passwd

# The job working directory cannot stay under /run: the rootless daemon has its own
sudo sed -i 's,^runtime_dir:.*,runtime_dir: /var/lib/mcp-coderunner-app/work,' \
  /etc/mcp-coderunner-app/config.yml
```

Images built by the rootful daemon stay with it and are invisible to the rootless
one, so the first job rebuilds its Blueprint.

### Check that the limits are real

**This is the step not to skip.** Everything else can look right while the limits are
being ignored, and a worker that reports limits it is not applying is worse than one
that refuses to run.

```sh
uid=$(id -u mcp-coderunner-app)

cat /sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers
# must list: cpu cpuset io memory pids

sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker run --rm --memory 64m --cpus 1 --pids-limit 32 alpine \
  sh -c 'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max /sys/fs/cgroup/pids.max'
# must print: 67108864 / 100000 100000 / 32
```

`max` anywhere in that output means the limit is not being enforced. Fix the
delegation before running anything real.

## 4. Firewall

This is the part that cannot slip. **Make the firewall enforce the LAN block.**

| Path | Policy |
|---|---|
| containers → the internet | allowed (the build phase needs it) |
| **containers → LAN** | **denied entirely (this is the part that cannot slip)** |
| the VM's own outbound | unrestricted |
| inbound | denied entirely |

The VM's own outbound is left alone because **once the build phase has a path out, the
exit is already open** (design §9.2 accepts this). Closing off the VM itself would buy
little for what it costs in updates and day-to-day operation. What is being protected is
reachability into the LAN, and inbound — and that does not change.

**Rootless changes how this has to be written.** There is no docker bridge to filter
on: rootlesskit carries the container's traffic through the host's own network stack,
so to the firewall it is traffic from the `mcp-coderunner-app` user. Match that, in
the output hook. A rule written against `docker0` — which is what a rootful setup
uses, and what this file said before — matches nothing here and protects nothing.

```
table inet mcp-coderunner-app {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid <uid> ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
    meta skuid <uid> ip6 daddr { fc00::/7, fe80::/10 } drop
  }
}
```

The worker runs as that user too, and has no reason to reach the LAN, so catching it
in the same rule costs nothing. Check it from a container, against something on the
LAN that answers:

```sh
uid=$(id -u mcp-coderunner-app)
sudo -u mcp-coderunner-app env DOCKER_HOST=unix:///run/user/$uid/docker.sock \
  docker run --rm alpine sh -c 'nc -z -w2 <the router> 80; echo "exit=$?"'
# must not be exit=0
```

Job containers run with `--network none`, so they cannot reach anything to begin with.
What this protects is the **build phase**, and together with Blueprint review it makes
two layers.

## 5. Install the units and start them

```sh
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-worker.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mcp-coderunner-app-worker.service
sudo systemctl enable --now mcp-coderunner-app-prune.timer
```

## 6. Check that it works

```sh
# one line per event
sudo journalctl -u mcp-coderunner-app-worker -f
```

It is working if the instance shows up at `/admin/workers` and its last heartbeat
advances every 30 seconds. The row carries a warning when its commit has drifted from
the server's.

One thing can be checked before any of this reaches the VM: whether plain ruby can load
the worker.

```sh
ruby -Ilib -I. -e 'require "worker/runner"'
```

When that fails, an ActiveSupport extension (`blank?`, `1.hour`, and the like) has found
its way into the worker or into `lib/protocol`. On a development machine it loads
anyway, by way of Rails, which is why human review does not catch it.

## Updating

```sh
sudo /opt/mcp-coderunner-app/deploy/update-worker.sh
```

It brings the checkout in line with `origin/main`, rewrites `REVISION`, and restarts the
unit. It uses `git reset --hard` rather than `git pull`, so the result is the same
whether or not the checkout was dirty. No `bundle install` (the worker is written
against stdlib alone).

**A human or a timer on the VM pulls the trigger. Never the VPS.** Wiring this to the
`outdated` flag in the heartbeat would let the VPS decide what code runs on the VM,
which knocks out the foundation: the worker does not trust the VPS.

Rolling back is the same procedure pointed at `git reset --hard <SHA>`. There is nothing
built, so moving the checkout and restarting is all of it.

On restart the worker calls `/deregister`, so a job that was mid-flight goes straight
back to the queue. Nothing waits for the lease to time out or for the heartbeat to
expire.

## When something is wrong

| Symptom | Where to look |
|---|---|
| a job sits in `queued` | Is the instance listed at `/admin/workers`? Is `drain` set (a protocol_version mismatch)? |
| `policy_rejected` comes back | The limits in `/etc/mcp-coderunner-app/config.yml`, and the paths in the Blueprint's context |
| `ruby: No such file or directory -- /work/script.rb` | The job's working directory is under /run. The rootless daemon has a /run of its own (rootlesskit `--copy-up=/run`), so it cannot see the one the worker wrote to, and docker mounts an empty directory in its place. Set `runtime_dir` to a path under `/var/lib/mcp-coderunner-app` |
| a build hangs, then fails on `apt-get update` | DNS. The container cannot reach the host's `127.0.0.53`; see "DNS for the build phase" |
| `image_build_failed` | The build log is at the tail of `job_results.stderr` |
| repeated 401s | Has the token been revoked (`/admin/workers`)? Did a newline get into `/etc/mcp-coderunner-app/token`? |
| `unknown flag: --tag` from a build | The docker CLI lost its plugin directory, and `build` is the buildx plugin. `ProtectHome=yes` turns the service's `$HOME/.docker` from missing into unreadable, which is what the CLI cannot take. The unit sets `DOCKER_CONFIG` for this; a unit older than that needs recopying |
| a job's limits do not match `applied_limits` | The cpu controller is not delegated. Section 3's check says so in one line; the drop-in under `/etc/systemd/system/user@.service.d/` is the fix, and it needs a reboot |
| `Unit docker.service not found` right after the setup tool wrote it | The home in `/etc/passwd` and the `HOME` the tool was given are different directories. See "Coming from the rootful setup" |
| the setup tool refuses: no subuid/subgid range | `useradd --system` does not allocate them. `sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 mcp-coderunner-app`, then restart the user's docker |
| `Cannot connect to the Docker daemon` | `/etc/mcp-coderunner-app/worker.env` is missing or has the wrong uid, or the user's daemon is not running: `sudo -u mcp-coderunner-app env XDG_RUNTIME_DIR=/run/user/$(id -u mcp-coderunner-app) systemctl --user status docker` |
| containers pile up | `docker ps -a --filter label=mcp-coderunner-app.job`. The unit sweeps them before it starts and after it stops |
