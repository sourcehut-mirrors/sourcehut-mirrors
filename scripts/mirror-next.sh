#!/usr/bin/env bash
#
# Mirror the *next* SourceHut repo in rotation, one per invocation.
#
# Called each tick by the container loop (docker/entrypoint.sh), or by any
# timer/cron, every INTERVAL. Each repo is then refreshed once every
# INTERVAL * N, where N is the number of entries in repos.txt, and only one
# clone/fetch ever runs at a time -- so git.sr.ht is never hit by the parallel
# burst that the old GitHub Actions matrix produced. Pick
# INTERVAL = target-refresh / N (e.g. 20 repos refreshed hourly -> 3m).
#
# Rotation is a plain round-robin over a state file rather than a
# clock-derived index: a late or skipped tick just resumes where it left
# off (covering every repo in order) instead of silently skipping one.
# Advancing the pointer *before* mirroring is deliberate -- a repo that
# fails is not retried in a tight loop; it comes back around next cycle
# (and mirror-one.sh already retries internally within a single attempt).
#
# Usage: mirror-next.sh
# Env:
#   GH_MIRROR_TOKEN   (required) passed through to mirror-one.sh
#   MIRROR_STATE_FILE (optional) rotation pointer, default .mirror-state
#   MIRROR_LOCK_FILE  (optional) overlap lock,      default .mirror.lock
#   MIRROR_DRY_RUN=1  (optional) print the selection and advance, don't mirror

set -uo pipefail

# Resolve to the repo root so repos.txt, scripts/, and the repos/ cache all
# resolve regardless of where the timer/cron invoked us from.
cd "$(dirname "$0")/.." || exit 1

: "${GH_MIRROR_TOKEN:?GH_MIRROR_TOKEN not set}"

STATE_FILE="${MIRROR_STATE_FILE:-.mirror-state}"
LOCK_FILE="${MIRROR_LOCK_FILE:-.mirror.lock}"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Never let a still-running mirror overlap the next tick: a hung transfer
# would otherwise stack connections and defeat the whole point. Non-blocking
# skip (don't advance the pointer) so ticks can't pile up.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "previous mirror tick still running, skipping"
    exit 0
  fi
fi

# Reuse gen-matrix.py's validated parser; a malformed repos.txt aborts the
# tick (exit 1, errors on stderr) instead of guessing a repo.
parsed="$(python3 scripts/gen-matrix.py repos.txt)" || exit 1
n="$(jq '.repos | length' <<<"$parsed")"
if ! [ "$n" -gt 0 ] 2>/dev/null; then
  log "no mirror entries found in repos.txt"
  exit 1
fi

# Read the previous index (default -1 -> start at 0); ignore a garbage file.
prev="$(cat "$STATE_FILE" 2>/dev/null || true)"
case "$prev" in
  ''|*[!0-9-]*) prev=-1 ;;
esac
idx=$(( (prev + 1) % n ))
printf '%s\n' "$idx" > "$STATE_FILE"

IFS=$'\t' read -r owner repo gh \
  < <(jq -r ".repos[$idx] | [.owner, .repo, .github_repo] | @tsv" <<<"$parsed")

log "tick $((idx + 1))/$n -> ~${owner}/${repo} => ${gh}"

if [ "${MIRROR_DRY_RUN:-}" = "1" ]; then
  log "dry run, not mirroring"
  exit 0
fi

scripts/mirror-one.sh "$owner" "$repo" "$gh"
