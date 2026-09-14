# Deploying

The VPS side. The worker VM is a separate procedure: [worker-setup.md](worker-setup.md)
([日本語](worker-setup.ja.md)).

The image is **built locally or in CI and pushed to ghcr.io, and the server only
pulls** — nothing is built on the VPS. An existing Caddy owns 80/443, and kamal-proxy
binds to `127.0.0.1:8080` behind it: Caddy hands requests over with
`reverse_proxy localhost:8080` (`deploy/Caddyfile.example`).

**The real address and hostname are not in this repository.** `config/deploy.yml`
reads them from the environment: from your shell by hand, from secrets in CI.

## What the application reads

| Variable | Purpose |
|---|---|
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL. Used for `review_url` and the OAuth metadata |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub sign-in |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | The login name that becomes admin on its first sign-in |
| `KAMAL_VERSION` | The deployed revision. Used to spot drift against the worker |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | Web Push. Without them the feature is absent: no button, no delivery |
| `VAPID_SUBJECT` | Where a push service reaches you: a `mailto:` or `https:` URI (RFC 8292). Unset, the public URL is used, which keeps a personal address out of a JWT bound for Apple and Google. Changing it does not invalidate subscriptions |

`allow_developer_login` belongs to the same list by implication: in development it is
true, and `/login` then offers a door that skips GitHub. **It must never be true in
production.** It bypasses the center of the authorization model — that an
authorization code is only ever issued to a session holding member or above. Where
the setting is off, `/auth/developer` does not exist at all.

## By hand

| Variable | Contents |
|---|---|
| `DEPLOY_HOST` | The VPS address |
| `DEPLOY_SSH_USER` | The ssh user to log in as (defaults to `root`) |
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL |
| `GITHUB_CLIENT_ID` / `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | GitHub sign-in settings |
| `KAMAL_REGISTRY_PASSWORD` | A ghcr.io token (a classic PAT with `write:packages`) |
| `GITHUB_CLIENT_SECRET` / `RAILS_MASTER_KEY` / `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | Secrets handed to the container (via `.kamal/secrets`) |
| `VAPID_SUBJECT` | Web Push, if you want one other than the public URL |

```sh
bin/kamal config     # print the resolved configuration; running this first prevents surprises
bin/kamal deploy
```

## From CI

Once a change lands on `main` and every CI job passes, the `deploy` job in
`.github/workflows/ci.yml` runs. It reaches the VPS over ssh with
[opkssh](https://github.com/openpubkey/opkssh), so **no long-lived private key sits in
CI or on the VPS** — it authenticates with the GitHub Actions OIDC token.

Pushing to ghcr.io and pulling from the VPS both use `GITHUB_TOKEN`. It is valid only
for the lifetime of the job, so **the credentials left behind on the VPS expire on the
same clock**. (Make the package public and pulling needs no credentials at all. Once
the repository is public the package can be too: the image holds nothing but published
source.)

The values live in the secrets of the GitHub environment named `production`. Only the
`deploy` job declares that environment, so no other job can read them. Adding a
reviewer to the environment turns deployment into a manual approval, if you want that.

| Secret | Contents |
|---|---|
| `DEPLOY_HOST` | The VPS address |
| `DEPLOY_SSH_USER` | The ssh user to log in as (defaults to `root`) |
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL |
| `OAUTH_GITHUB_CLIENT_ID` / `OAUTH_GITHUB_CLIENT_SECRET` | GitHub sign-in. **A secret's name cannot start with `GITHUB_`**, so they are stored under another name and copied across in the workflow |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | The login name that becomes admin on its first sign-in |
| `RAILS_MASTER_KEY` | The contents of `config/master.key` |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` | Web Push, if you want it |

## kamal-proxy behind Caddy

Requests travel Caddy (80/443, TLS) → `127.0.0.1:8080` → kamal-proxy → the
container's port 80. kamal-proxy picks the application by the Host header, so another
Kamal app on the VPS needs a `proxy.host` of its own and no change to the Caddyfile.
On a deploy it boots the new container, waits for `/up`, and only then drains and
stops the old one.

Three values under `proxy.run` in `config/deploy.yml` are not incidental:

- **`bind_ips: [127.0.0.1]`.** Docker publishes ports with its own iptables rules,
  ahead of the firewall's INPUT chain. Bound to every interface, 8080 would be
  reachable from the internet whatever ufw says.
- **`https_port: 8443`.** Nothing is served there, since TLS ends at Caddy, but the
  default of 443 would collide with Caddy.
- **`run` belongs to the host, not the app.** kamal-proxy keeps running with whichever
  values booted it first; later deploys only start it. This app was the first on the
  VPS, so its values are the reference, and another Kamal app added later has to
  carry the same ones.

## Web Push

A Blueprint arriving for review is the only thing that notifies anyone, and only if
this is set up. Generate the pair once:

```sh
bin/rails runner 'k = WebPush.generate_key; puts "public: #{k.public_key}"; puts "private: #{k.private_key}"'
```

Put them in the environment: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and
`VAPID_SUBJECT`, which for CI means the `production` environment's secrets.
Leaving them unset deploys fine — the feature is simply not there. **Keep them.** Replacing the pair invalidates every subscription made against the old one,
silently — the browsers keep their subscriptions and the notifications stop arriving.

Then open `/admin/blueprints` and press the button. Subscriptions belong to a
browser, not an account, so each device does it once.

**On iOS it only works from the Home Screen.** Safari does not offer Web Push to an
ordinary tab, so add the site to the Home Screen and press the button there. The
button says as much when it finds itself in a tab.

## opkssh on the VPS

Install opkssh and allow GitHub Actions as an issuer.

```
# /etc/opk/providers
https://token.actions.githubusercontent.com github oidc

# /etc/opk/auth_id  (<the Linux user to log in as> <principal> <issuer>)
root repo:unasuke@4487291/mcp-coderunner-app@1365649101:environment:production https://token.actions.githubusercontent.com
```

`~/.opk/auth_id`, owned by that user and mode 600, works the same and needs no root.

**The principal is the `sub` of the OIDC token, exactly.** Two things shape it, and
both are easy to get wrong:

- **Write it in terms of the environment.** A job that declares one gets
  `...:environment:production`, not `...:ref:refs/heads/main`. Written as a branch, it
  is rejected.
- **The ids belong in it.** Since 2026-07-15 GitHub puts immutable ids in the subject
  — `owner@<owner id>/repo@<repo id>` — for every repository created, renamed, or
  transferred from that date on. Without them a name that someone else later takes
  over would present the same subject. Read the ids with:

  ```sh
  gh api repos/OWNER/REPO --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
  ```

  An older repository that has not been renamed still uses the plain names.

That single line is the only gate keeping everything but the `deploy` job on `main`
out: CI on a branch or a fork cannot declare the environment, so its principal will
never match.

## When a deploy goes wrong

kamal-proxy checks `/up` on the new container. **One that does not answer 200 within
`deploy_timeout` (30 seconds) fails the deploy, and the old container keeps serving.**

| Symptom | Cause |
|---|---|
| `target failed to become healthy` | The new container did not answer 200 on `/up` in time. `bin/kamal app logs` says why; an empty `RAILS_MASTER_KEY` (below) ends up here |
| `Bind for 127.0.0.1:8080 failed: port is already allocated` while booting kamal-proxy | Something else on the VPS holds 8080 |
| The deploy is green but the site answers 502 | Caddy is still pointed at the old port (7000). kamal-proxy listens on `127.0.0.1:8080` |
| Every request answers 502, deploy or not | kamal-proxy is not running. `bin/kamal proxy details` and `bin/kamal proxy logs` say why; `bin/kamal proxy boot` brings it back |
| `Missing secret_key_base for 'production'` in the container log | `RAILS_MASTER_KEY` is empty. CI writes `config/master.key` from the secret, and an unset secret writes an empty file rather than failing |
| `Net::SSH::AuthenticationFailed` | The opkssh principal and the token's `sub` disagree. `/var/log/opkssh.log` on the VPS says which subject it saw, and `no policy to allow` there means exactly this. The empty name in that message is the email claim, which a GitHub Actions token does not have — not the problem |
| `lstat /vendor: no such file or directory` while building | Kamal builds from a clone of HEAD ("Building from a local git clone…"), so anything untracked is absent. A file the Dockerfile copies has to be committed, whatever a local or global ignore says |
