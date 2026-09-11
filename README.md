# 📋 mcp-coderunner-app

An MCP server that takes a Dockerfile and a script, and runs the script in a
resource-limited container. Built to try out Ractor behavior and run benchmarks
without dirtying the machine I work on.

- **VPS (Rails)** — authentication, authorization, the MCP endpoint, the review UI
- **Home VM (worker)** — polls outbound-only and drives docker

Nothing listens on the home side. Job containers always run with `--network none`.

The design lives in `.claude/plans/ruby-exec-mcp-design.md` (not in git). This file
does not explain the design.

## Layout

```
app/                 Rails: models, controllers, MCP tools, /admin
lib/protocol/        DTOs and constants shared by Rails and the worker (stdlib only)
worker/              the side that drives docker (stdlib only; never loads Rails)
bin/worker           the long-running process on the VM
deploy/              systemd units and an example Caddyfile
docs/worker-setup.md how to set up the VM
```

## Development

```sh
bin/setup            # install dependencies, db:prepare, start the dev server
bin/dev              # web + js + worker (the worker's token is issued on first run)
bin/rails test       # the Rails-side tests
bin/ci               # lint, security, and the full test suite

# The worker does not load Rails. Run it with plain ruby.
ruby -Ilib -I. -e 'require "worker/runner"'
ruby -Ilib -I. worker/test/policy_test.rb

# The end-to-end test that actually drives docker (slow)
MCP_CODERUNNER_APP_E2E=1 ruby -Ilib -I. worker/test/e2e_test.rb
```

Point an MCP client at `http://localhost:3000/mcp` over Streamable HTTP. Issue the
access token from `/admin` after signing in.

## Environment variables

Read by the application.

| Variable | Purpose |
|---|---|
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL. Used for `review_url` and the OAuth metadata |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | GitHub sign-in |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | The login name that becomes admin on its first sign-in |
| `KAMAL_VERSION` | The deployed revision. Used to spot drift against the worker |

## The developer sign-in

In development, `allow_developer_login` in `config/mcp_coderunner_app.yml` is true,
so `/login` offers "sign in without going through GitHub". Enter `dev` to land as an
admin; any other name lands as pending, which is how you exercise the waiting-for-
approval path.

**Never turn this on in production.** It bypasses the center of the authorization
model, which is that an authorization code is only ever issued to a session holding
member or above. Where the setting is off, `/auth/developer` does not exist at all.

## Deployment

The VPS runs under Kamal; the worker runs under systemd (`docs/worker-setup.md`).

The image is **built locally or in CI and pushed to ghcr.io, and the server only
pulls**. Nothing is built on the VPS. An existing Caddy owns 80/443, so kamal-proxy
is disabled.

**The real address and hostname are not in this repository.** `config/deploy.yml`
reads them from the environment variables below: from your shell when you deploy by
hand, from secrets when CI does.

| Variable | Contents |
|---|---|
| `DEPLOY_HOST` | The VPS address |
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL |
| `GITHUB_CLIENT_ID` / `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | GitHub sign-in settings |
| `KAMAL_REGISTRY_PASSWORD` | A ghcr.io token (a classic PAT with `write:packages`) |
| `GITHUB_CLIENT_SECRET` / `RAILS_MASTER_KEY` | Secrets handed to the container (via `.kamal/secrets`) |

```sh
bin/kamal config     # print the resolved configuration; running this first prevents surprises
bin/kamal deploy
```

### Deploying from CI

Once a change lands on `main` and every CI job passes, the `deploy` job in
`.github/workflows/ci.yml` runs. It reaches the VPS over ssh with
[opkssh](https://github.com/openpubkey/opkssh), so **no long-lived private key sits
in CI or on the VPS** — it authenticates with the GitHub Actions OIDC token.

Pushing to ghcr.io and pulling from the VPS both use `GITHUB_TOKEN`. It is valid only
for the lifetime of the job, so **the credentials left behind on the VPS expire on the
same clock** (make the package public and pulling needs no credentials at all).

The values live in the secrets of the GitHub environment named `production`. Only the
`deploy` job declares that environment, so no other job can read them. Adding a
reviewer to the environment turns deployment into a manual approval, if you want that.

The secrets it needs:

| Secret | Contents |
|---|---|
| `DEPLOY_HOST` | The VPS address |
| `DEPLOY_SSH_USER` | The ssh user to log in as (defaults to `root`) |
| `MCP_CODERUNNER_APP_BASE_URL` | Public URL |
| `OAUTH_GITHUB_CLIENT_ID` / `OAUTH_GITHUB_CLIENT_SECRET` | GitHub sign-in. **A secret's name cannot start with `GITHUB_`**, so they are stored under another name and copied across in the workflow |
| `BOOTSTRAP_ADMIN_GITHUB_LOGIN` | The login name that becomes admin on its first sign-in |
| `RAILS_MASTER_KEY` | The contents of `config/master.key` |

On the VPS, install opkssh and allow GitHub Actions as an issuer.

```
# /etc/opk/providers
https://token.actions.githubusercontent.com github oidc

# /etc/opk/auth_id  (<the Linux user to log in as> <principal> <issuer>)
root repo:unasuke/mcp-coderunner-app:environment:production https://token.actions.githubusercontent.com
```

**Write the principal in terms of the environment.** When a job declares an
environment, the `sub` of its OIDC token becomes `...:environment:production` rather
than `...:ref:refs/heads/main`. Written as a branch, it is rejected.

That single line is the only gate keeping everything but the `deploy` job on `main`
out: CI on a branch or a fork cannot declare the environment, so its principal will
never match.

Once the repository is public the package can be public too. The image holds nothing
but published source, so there is nothing to hide, and a public package lets the
server pull without credentials.

## License

MIT License ([LICENSE](LICENSE))
