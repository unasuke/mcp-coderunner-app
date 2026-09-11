# 📋 mcp-coderunner-app

An MCP server that takes a Dockerfile and a script, and runs the script in a
resource-limited container. Built to try out Ractor behavior and run benchmarks
without dirtying the machine I work on.

- **VPS (Rails)** — authentication, authorization, the MCP endpoint, the review UI
- **Home VM (worker)** — polls outbound-only and drives docker

Nothing listens on the home side. Job containers always run with `--network none`.
Every Dockerfile is reviewed by a human before anything runs on it.

This is a personal setup, run by one person. The design lives in
`.claude/plans/ruby-exec-mcp-design.md`, which is not in git.

```
app/                 Rails: models, controllers, MCP tools, /admin
lib/protocol/        DTOs and constants shared by Rails and the worker (stdlib only)
worker/              the side that drives docker (stdlib only; never loads Rails)
bin/worker           the long-running process on the VM
deploy/              systemd units and an example Caddyfile
```

## Development

```sh
bin/setup            # install dependencies, db:prepare, start the dev server
bin/dev              # web + js + worker (the worker's token is issued on first run)
bin/ci               # lint, security, and the full test suite

# The worker does not load Rails. Run it with plain ruby.
ruby -Ilib -I. -e 'require "worker/runner"'
ruby -Ilib -I. worker/test/policy_test.rb

# The end-to-end test that actually drives docker (slow)
MCP_CODERUNNER_APP_E2E=1 ruby -Ilib -I. worker/test/e2e_test.rb
```

Point an MCP client at `http://localhost:3000/mcp` over Streamable HTTP. Issue the
access token from `/admin` after signing in — in development, `/login` also offers a
door that skips GitHub (`dev` lands as an admin).

## Operating it

- [docs/deployment.md](docs/deployment.md) — the VPS: Kamal, ghcr.io, opkssh, the
  secrets CI needs, and what the failures mean
- [docs/worker-setup.md](docs/worker-setup.md) — the VM, from a bare machine to a
  running worker ([日本語](docs/worker-setup.ja.md))

## License

MIT License ([LICENSE](LICENSE))
