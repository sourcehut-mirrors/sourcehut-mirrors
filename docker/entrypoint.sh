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
REPOS_FILE="${REPOS_FILE:-/data/repos.txt}"
REPOS_URL="${REPOS_URL:-}"
export REPOS_FILE

cd /app || exit 1

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Seed the working copy from the image's baked-in list if we have none yet, so
# a first boot with no network still has something to mirror from.
[ -f "$REPOS_FILE" ] || cp /app/repos.txt "$REPOS_FILE"

# Poll GitHub for the latest repos.txt so pushing to the repo updates the
# server on the next tick, no rebuild or redeploy. Best-effort and defensive:
# a network blip keeps the last good copy, and a malformed fetched file is
# rejected (validated with gen-matrix.py) rather than allowed to halt mirroring.
refresh_repos() {
  [ -n "$REPOS_URL" ] || return 0
  local tmp
  # Same dir as the target so the swap below is an atomic same-filesystem rename.
  tmp="$(mktemp "${REPOS_FILE}.XXXXXX")" || return 0
  if curl -fsS --max-time 30 -o "$tmp" "$REPOS_URL"; then
    if [ -s "$tmp" ] && ! cmp -s "$tmp" "$REPOS_FILE"; then
      if python3 scripts/gen-matrix.py "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$REPOS_FILE"
        log "repos.txt updated from $REPOS_URL"
      else
        log "fetched repos.txt is invalid, keeping current copy"
      fi
    fi
  else
    log "repos.txt refresh failed, using last copy"
  fi
  rm -f "$tmp"
}

if [ "${MIRROR_ONCE:-}" = "1" ]; then
  refresh_repos
  exec scripts/mirror-next.sh
fi

run=1
trap 'run=0' TERM INT

log "mirror loop starting (interval=${INTERVAL})"
while [ "$run" = 1 ]; do
  refresh_repos
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
