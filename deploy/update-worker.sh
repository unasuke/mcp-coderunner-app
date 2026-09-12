#!/bin/sh
# Brings the worker in line with origin/main. Run as root.
#
#   sudo /opt/mcp-coderunner-app/deploy/update-worker.sh
#
# No bundle install. The worker is written against stdlib alone, so the files, the
# units and a restart are all of it.
#
# The units are reinstalled from the checkout every time. They change as often as
# the code does -- rootless brought an EnvironmentFile, DOCKER_CONFIG and
# ProtectHome=no -- and a VM that only ever pulls would keep running the unit it
# was first given while believing it was up to date. Drop-ins under
# /etc/systemd/system/<unit>.d/ are left alone.
#
# A restart interrupts whatever was running. The worker holds its lease, calls
# /deregister on the way out, and the job returns to the queue without consuming
# an attempt; the worker that comes up next picks it back up.
set -eu

# Everything lives in main(), called on the last line. This script replaces itself
# with `git reset --hard` while it is running, and sh reads a script as it goes: a
# file that changes underneath it can carry execution into the middle of a line.
# Wrapped this way, the whole body is parsed before any of it runs.
main() {

  CHECKOUT="${CHECKOUT:-/opt/mcp-coderunner-app}"
  BRANCH="${BRANCH:-main}"
  UNIT="${UNIT:-mcp-coderunner-app-worker}"
  UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"

  cd "$CHECKOUT"

  before="$(git rev-parse --short HEAD)"

  git fetch --prune origin
  # reset, not pull, so a dirty checkout still converges to one known state
  git reset --hard "origin/${BRANCH}"

  after="$(git rev-parse --short HEAD)"

  if [ "$before" = "$after" ]; then
    echo "already at ${after}; reinstalling units and restarting"
  fi

  # Forget this and the drift warning at /admin/workers starts lying
  git rev-parse HEAD > REVISION

  for unit in mcp-coderunner-app-worker.service \
              mcp-coderunner-app-prune.service \
              mcp-coderunner-app-prune.timer; do
    install -m 0644 "deploy/${unit}" "${UNIT_DIR}/${unit}"
  done
  systemctl daemon-reload

  systemctl restart "$UNIT"

  echo "restarted: ${before} -> ${after}"
  systemctl --no-pager --lines=0 status "$UNIT" || true
}

main "$@"
