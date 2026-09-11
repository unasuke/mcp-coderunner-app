# Setting up the worker

*[日本語](worker-setup.ja.md)*

How to get `bin/worker` running on the home VM. **The reasoning behind this shape is in
the design document**, so this file is procedure only. The bar it aims at: that I can
rebuild the VM from it a few months from now.

## Assumptions

- **Ruby 3.3 or newer**, and Docker. Nothing else: no bundler, no synced Gemfile.lock (the worker is written against stdlib alone), and no need to match the Ruby the VPS runs.
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
sudo useradd --system --no-create-home --shell /usr/sbin/nologin mcp-coderunner-app
sudo usermod -aG docker mcp-coderunner-app

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

## 3. Firewall

This is the part that cannot slip. **Make the firewall enforce the LAN block.**

| Path | Policy |
|---|---|
| container bridge → the internet | allowed (the build phase needs it) |
| **container bridge → LAN** | **denied entirely (this is the part that cannot slip)** |
| the VM's own outbound | unrestricted |
| inbound | denied entirely |

The VM's own outbound is left alone because **once the build phase has a path out, the
exit is already open** (design §9.2 accepts this). Closing off the VM itself would buy
little for what it costs in updates and day-to-day operation. What is being protected is
reachability into the LAN, and inbound — and that does not change.

Under nftables, drop traffic leaving docker's bridge (`docker0` and `172.17.0.0/16` by
default) for an RFC1918 address.

```
table inet mcp-coderunner-app {
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "docker0" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
  }
}
```

Job containers run with `--network none`, so they cannot reach anything to begin with.
What this protects is the **build phase**, and together with Blueprint review it makes
two layers.

## 4. Install the units and start them

```sh
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-worker.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.service /etc/systemd/system/
sudo cp /opt/mcp-coderunner-app/deploy/mcp-coderunner-app-prune.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mcp-coderunner-app-worker.service
sudo systemctl enable --now mcp-coderunner-app-prune.timer
```

## 5. Check that it works

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
| `image_build_failed` | The build log is at the tail of `job_results.stderr` |
| repeated 401s | Has the token been revoked (`/admin/workers`)? Did a newline get into `/etc/mcp-coderunner-app/token`? |
| containers pile up | `docker ps -a --filter label=mcp-coderunner-app.job`. The unit sweeps them before it starts and after it stops |
