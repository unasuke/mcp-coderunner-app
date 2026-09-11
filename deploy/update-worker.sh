#!/bin/sh
# Brings the worker in line with origin/main. Run as root.
#
#   sudo /opt/mcp-coderunner-app/deploy/update-worker.sh
#
# No bundle install. The worker is written against stdlib alone, so replacing the
# files and restarting is all of it.
#
# A restart interrupts whatever was running, but the shutdown path calls
# /deregister, so those jobs return to the queue without consuming an attempt.
# The worker that comes up next picks them back up.
set -eu

CHECKOUT="${CHECKOUT:-/opt/mcp-coderunner-app}"
BRANCH="${BRANCH:-main}"
UNIT="${UNIT:-mcp-coderunner-app-worker}"

cd "$CHECKOUT"

before="$(git rev-parse --short HEAD)"

git fetch --prune origin
# reset, not pull, so a dirty checkout still converges to one known state
git reset --hard "origin/${BRANCH}"

after="$(git rev-parse --short HEAD)"

if [ "$before" = "$after" ]; then
  echo "already at ${after}; restarting only"
fi

# Forget this and the drift warning at /admin/workers starts lying
git rev-parse HEAD > REVISION

running="$(docker ps -q --filter label=mcp-coderunner-app.job | wc -l)"
if [ "$running" -gt 0 ]; then
  echo "interrupting ${running} running job(s); they return to the queue"
fi

systemctl restart "$UNIT"

echo "restarted: ${before} -> ${after}"
systemctl --no-pager --lines=0 status "$UNIT" || true
