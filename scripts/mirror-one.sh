#!/usr/bin/env bash
#
# Mirror one SourceHut repo to github.com/sourcehut-mirrors.
# Usage: mirror-one.sh <sourcehut-owner> <sourcehut-repo> [github-repo-name]
#
# Exits 0 on success or on a graceful skip (upstream not found), 1 on a
# real failure. Never `set -e`: LAST_OUTPUT is populated via command
# substitution and its exit status must be inspected explicitly.

set -uo pipefail

OWNER="${1:?usage: mirror-one.sh <owner> <repo> [github-repo-name]}"
REPO="${2:?usage: mirror-one.sh <owner> <repo> [github-repo-name]}"
GH_NAME="${3:-$REPO}"

: "${GH_MIRROR_TOKEN:?GH_MIRROR_TOKEN not set}"

# Never hang waiting for credentials on a broken/private URL.
export GIT_TERMINAL_PROMPT=0

SRC_URL="https://git.sr.ht/~${OWNER}/${REPO}"
DST_URL="https://x-access-token:${GH_MIRROR_TOKEN}@github.com/sourcehut-mirrors/${GH_NAME}.git"
CACHE_DIR="repos/${GH_NAME}"
GITHUB_API="https://api.github.com/repos/sourcehut-mirrors/${GH_NAME}"

RETRY_MAX=3
RETRY_DELAY=10
OP_TIMEOUT=300

# Abort a stalled transfer well before OP_TIMEOUT, so a hung connection
# doesn't burn a whole attempt's budget.
GIT_OPTS=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30)

log()    { printf '%s\n' "$*"; }
warn()   { printf '::warning::[%s] %s\n' "$GH_NAME" "$*"; }
notice() { printf '::notice::[%s] %s\n' "$GH_NAME" "$*"; }

is_missing_upstream() {
  grep -qiE "repository '[^']*' not found|returned error: 404" <<<"$1"
}

is_corrupt_cache() {
  grep -qiE "bad object|loose object|object file .* is empty|fatal: not a git repository|unable to read|missing blob|fatal: fsck" <<<"$1"
}

is_default_branch_delete_rejected() {
  grep -qi "refusing to delete the current branch" <<<"$1"
}

github_api() {
  curl -fsS --max-time 30 -H "Authorization: Bearer ${GH_MIRROR_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

# Best-effort: point GitHub's configured default branch at upstream's
# default branch before pushing. GitHub refuses to let `push --mirror`
# delete whatever branch is currently set as default, so if upstream's
# default branch was renamed (old one gone, new one created), the push
# would otherwise fail on that one ref forever, not just transiently.
sync_github_default_branch() {
  local branch="$1" current
  current="$(github_api "$GITHUB_API" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null)"
  if [ -z "$current" ] || [ "$current" = "$branch" ]; then
    return 0
  fi
  warn "GitHub default branch is '$current' but upstream's is '$branch', repointing before push"
  github_api -X PATCH "$GITHUB_API" -d "$(jq -n --arg b "$branch" '{default_branch: $b}')" >/dev/null 2>&1 \
    || warn "could not update GitHub default branch via API (check GH_MIRROR_TOKEN permissions)"
}

# run_with_retry <max-attempts> <initial-delay-seconds> -- <command...>
# Sets LAST_OUTPUT to the combined stdout/stderr of the final attempt.
run_with_retry() {
  local max="$1" delay="$2"; shift 2
  local attempt=1 rc
  while true; do
    LAST_OUTPUT="$("$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -n "$LAST_OUTPUT" ] && log "$LAST_OUTPUT"
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      return "$rc"
    fi
    warn "attempt $attempt/$max failed (exit $rc), retrying in ${delay}s"
    log "$LAST_OUTPUT"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 3))
  done
}

mkdir -p "$(dirname "$CACHE_DIR")"

if [ -d "$CACHE_DIR" ]; then
  log "[$GH_NAME] fetching (cache hit)"
  if ! run_with_retry "$RETRY_MAX" "$RETRY_DELAY" timeout "$OP_TIMEOUT" \
      git "${GIT_OPTS[@]}" -C "$CACHE_DIR" fetch --prune --prune-tags origin; then
    if is_missing_upstream "$LAST_OUTPUT"; then
      warn "~${OWNER}/${REPO} not found on SourceHut, skipping this run and keeping the last known mirror"
      exit 0
    elif is_corrupt_cache "$LAST_OUTPUT"; then
      warn "cached clone looks corrupt, discarding it and re-cloning from scratch"
      rm -rf "$CACHE_DIR"
    else
      log "$LAST_OUTPUT" >&2
      warn "fetch failed after retries, leaving cache in place for the next run"
      exit 1
    fi
  fi
fi

if [ ! -d "$CACHE_DIR" ]; then
  log "[$GH_NAME] cloning ~${OWNER}/${REPO} from scratch"
  if ! run_with_retry "$RETRY_MAX" "$RETRY_DELAY" timeout "$OP_TIMEOUT" \
      git "${GIT_OPTS[@]}" clone --mirror "$SRC_URL" "$CACHE_DIR"; then
    if is_missing_upstream "$LAST_OUTPUT"; then
      warn "~${OWNER}/${REPO} not found on SourceHut, skipping"
      exit 0
    fi
    log "$LAST_OUTPUT" >&2
    warn "clone failed after retries"
    exit 1
  fi
fi

# Best-effort: keep the mirror's default branch pointer, and GitHub's
# configured default branch, in sync with upstream, so a renamed default
# branch (e.g. master -> main) carries through the push instead of leaving
# HEAD pointing at a deleted ref or the push getting rejected (see
# sync_github_default_branch above).
default_ref="$(timeout "$OP_TIMEOUT" git "${GIT_OPTS[@]}" ls-remote --symref "$SRC_URL" HEAD 2>/dev/null | awk '/^ref:/ {print $2; exit}')"
default_branch_name=""
if [ -n "$default_ref" ]; then
  git -C "$CACHE_DIR" symbolic-ref HEAD "$default_ref" 2>/dev/null || true
  default_branch_name="${default_ref#refs/heads/}"
  sync_github_default_branch "$default_branch_name"
fi

log "[$GH_NAME] pushing to github.com/sourcehut-mirrors/${GH_NAME}"
if ! run_with_retry "$RETRY_MAX" "$RETRY_DELAY" timeout "$OP_TIMEOUT" \
    git "${GIT_OPTS[@]}" -C "$CACHE_DIR" push --mirror "$DST_URL"; then
  if is_default_branch_delete_rejected "$LAST_OUTPUT" && [ -n "$default_branch_name" ]; then
    warn "push rejected because GitHub's default branch still points at a branch missing upstream, re-syncing and retrying once"
    sync_github_default_branch "$default_branch_name"
    if run_with_retry 1 0 timeout "$OP_TIMEOUT" git "${GIT_OPTS[@]}" -C "$CACHE_DIR" push --mirror "$DST_URL"; then
      notice "mirrored successfully after default-branch resync"
      exit 0
    fi
  fi
  if is_missing_upstream "$LAST_OUTPUT"; then
    warn "github.com/sourcehut-mirrors/${GH_NAME} does not exist yet, create the destination repo first"
  fi
  log "$LAST_OUTPUT" >&2
  warn "push failed after retries"
  exit 1
fi

notice "mirrored successfully"
