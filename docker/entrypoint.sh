#!/usr/bin/env bash
#
# Container entry point: mirror one SourceHut repo, sleep, repeat -- forever.
#
# mirror-next.sh advances a round-robin pointer each call, so this loop walks
# the whole of repos.txt one repo at a time, never opening a second clone
# while one is in flight (that parallel burst is exactly what we're avoiding).
# With N repos and MIRROR_INTERVAL between ticks, each repo refreshes about
# every MIRROR_INTERVAL * N; set MIRROR_INTERVAL = target-refresh / N.
#
# Set MIRROR_ONCE=1 to run a single tick and exit instead of looping -- for
# driving the image from an external scheduler (host cron, k8s CronJob, ...).
#
# Runs as PID 1 under tini; SIGTERM/SIGINT stop it promptly (mid-sleep too).

set -uo pipefail

: "${GH_MIRROR_TOKEN:?GH_MIRROR_TOKEN not set}"
INTERVAL="${MIRROR_INTERVAL:-18m}"

cd /app || exit 1

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

if [ "${MIRROR_ONCE:-}" = "1" ]; then
  exec scripts/mirror-next.sh
fi

run=1
trap 'run=0' TERM INT

log "mirror loop starting (interval=${INTERVAL})"
while [ "$run" = 1 ]; do
  # A failing tick (upstream 404, transient network) must not kill the loop;
  # mirror-next.sh has already advanced the pointer, so the next tick moves on.
  scripts/mirror-next.sh || log "tick exited non-zero, continuing"
  [ "$run" = 1 ] || break
  # Background sleep + wait so a signal interrupts the wait immediately
  # instead of hanging until the full interval elapses.
  sleep "$INTERVAL" &
  wait "$!" 2>/dev/null || true
done
log "mirror loop stopped"
