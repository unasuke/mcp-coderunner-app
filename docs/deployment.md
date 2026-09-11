# Deploying

The VPS side. The worker VM is a separate procedure: [worker-setup.md](worker-setup.md)
([日本語](worker-setup.ja.md)).

The image is **built locally or in CI and pushed to ghcr.io, and the server only
pulls** — nothing is built on the VPS. An existing Caddy owns 80/443, so kamal-proxy
is off: the container publishes to `127.0.0.1:7000` and Caddy reaches it with
`reverse_proxy localhost:7000` (`deploy/Caddyfile.example`).

**The real address and hostname are not in this repository.** `config/deploy.yml`
reads them from the environment: from your shell by hand, from secrets in CI.

## What the application reads

| Variable | Purpose |
|---|---|
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL. Used for `review_url` and the OAuth metadata |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub sign-in |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | The login name that becomes admin on its first sign-in |
| `KAMAL_VERSION` | The deployed revision. Used to spot drift against the worker |

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
| `GITHUB_CLIENT_SECRET` / `RAILS_MASTER_KEY` | Secrets handed to the container (via `.kamal/secrets`) |

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

## Why the deploy job stops the container first

Kamal boots the new container and stops the old one afterwards. That order is right
when a proxy owns the port and can switch between them. Nothing owns the port here
but the container itself, which publishes `127.0.0.1:7000`, so **the old container
has to let go before the new one can bind** — and `kamal deploy` alone would fail on
`Bind for 127.0.0.1:7000 failed: port is already allocated` on every deploy after the
first. (`stale_containers --stop`, which `deploy` runs, deliberately spares the
version that is currently running.)

So the job splits what `kamal deploy` does:

```sh
bin/kamal build deliver      # build, push, pull onto the server
bin/kamal app stop           # release 127.0.0.1:7000
bin/kamal deploy --skip-push # boot the new one
```

The site is down between the stop and the boot — seconds, because the image is
already on the server — and a container that fails to start leaves it down rather
than falling back to the old one. Both are acceptable here and neither would be if
this were shared. The way out of both is kamal-proxy bound to a private port, with
Caddy in front of it; that also gives real HTTP health checks.

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

Kamal runs with the proxy disabled, so all it checks is that the container is still
running after a readiness delay. **A container that boots, fails, and exits can still
be reported as a successful deploy.** `curl -f "$MCP_CODERUNNER_APP_BASE_URL/up"`
answers the question the deploy does not.

| Symptom | Cause |
|---|---|
| `Bind for 127.0.0.1:7000 failed: port is already allocated` | A container from an earlier deploy still holds the port, including one stuck in a restart loop. `docker rm -f $(docker ps -aq --filter label=service=mcp_coderunner_app)` on the VPS clears it |
| The deploy is green but the site answers 502 | Caddy is still pointed at the old port. The container publishes to `127.0.0.1:7000` |
| `Missing secret_key_base for 'production'` in the container log | `RAILS_MASTER_KEY` is empty. CI writes `config/master.key` from the secret, and an unset secret writes an empty file rather than failing |
| `Net::SSH::AuthenticationFailed` | The opkssh principal and the token's `sub` disagree. `/var/log/opkssh.log` on the VPS says which subject it saw, and `no policy to allow` there means exactly this. The empty name in that message is the email claim, which a GitHub Actions token does not have — not the problem |
| `lstat /vendor: no such file or directory` while building | Kamal builds from a clone of HEAD ("Building from a local git clone…"), so anything untracked is absent. A file the Dockerfile copies has to be committed, whatever a local or global ignore says |
