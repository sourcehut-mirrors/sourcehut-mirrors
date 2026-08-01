#!/usr/bin/env bash
#
# Publish a Shields "endpoint" badge + basic stats as a single JSON file on a
# branch of the control repo, ONE commit per call, via the GitHub Contents API.
#
# Called once per mirror tick by mirror-next.sh. Each commit lands on
# BADGE_BRANCH (gh-pages) which -- like the default branch -- counts toward the
# account's GitHub contribution graph, so that graph doubles as a bot-uptime
# gauge (one green square's worth of commits per tick the bot was alive).
#
# Usage: update-badge.sh <owner> <repo> <github_repo> <mirror_rc> <index> <total>
#
# No-op (exit 0) unless BADGE_BRANCH is set, so local/dev runs don't publish.
# BADGE_DRY_RUN=1 prints the request instead of sending it. Best-effort: the
# caller ignores failures so a badge hiccup never affects mirroring.
#
# The commit author/committer email must be verified on the GitHub account for
# the commit to count as a contribution (BADGE_AUTHOR_EMAIL). The token needs
# Contents:write on BADGE_REPO (the same GH_MIRROR_TOKEN, if it can reach the
# control repo -- fine-grained tokens must include it in their repo selection).

set -uo pipefail

OWNER="${1:?usage: update-badge.sh <owner> <repo> <github_repo> <rc> <index> <total>}"
REPO="${2:?}"; GH="${3:?}"; RC="${4:?}"; IDX="${5:?}"; TOTAL="${6:?}"

BRANCH="${BADGE_BRANCH:-}"
[ -n "$BRANCH" ] || exit 0

: "${GH_MIRROR_TOKEN:?GH_MIRROR_TOKEN not set}"
BADGE_REPO="${BADGE_REPO:-sourcehut-mirrors/sourcehut-mirrors}"
BADGE_PATH="${BADGE_PATH:-badge/last-mirror.json}"
AUTHOR_NAME="${BADGE_AUTHOR_NAME:-sourcehut-mirrors}"
AUTHOR_EMAIL="${BADGE_AUTHOR_EMAIL:-sourcehut-mirrors@pm.me}"

ts="$(date -u +'%Y-%m-%d %H:%M UTC')"
if [ "$RC" -eq 0 ]; then ok=true; color=green; else ok=false; color=orange; fi

# One JSON file: the four shields.io endpoint fields plus a `last` object of
# human-readable stats (ignored by shields, handy for anyone who fetches it).
content="$(jq -n \
  --arg msg "${GH} · ${ts}" --arg color "$color" \
  --arg owner "$OWNER" --arg repo "$REPO" --arg gh "$GH" --arg ts "$ts" \
  --argjson ok "$ok" --argjson idx "$IDX" --argjson total "$TOTAL" \
  '{schemaVersion: 1, label: "last mirror", message: $msg, color: $color,
    last: {at: $ts, source: ("~" + $owner + "/" + $repo), github_repo: $gh,
           ok: $ok, position: $idx, total: $total}}')"

commit_msg="Mirror ~${OWNER}/${REPO} (${IDX}/${TOTAL}) — ${ts}"

if [ "${BADGE_DRY_RUN:-}" = "1" ]; then
  printf 'PUT %s on %s:%s as %s <%s>\ncommit: %s\n%s\n' \
    "$BADGE_PATH" "$BADGE_REPO" "$BRANCH" "$AUTHOR_NAME" "$AUTHOR_EMAIL" \
    "$commit_msg" "$content"
  exit 0
fi

api="https://api.github.com/repos/${BADGE_REPO}/contents/${BADGE_PATH}"
auth=(-H "Authorization: Bearer ${GH_MIRROR_TOKEN}" -H "Accept: application/vnd.github+json")

# Current blob sha for the file (empty => the PUT creates it). No -f: a 404
# body simply has no .sha, which we treat as "create".
sha="$(curl -sS --max-time 30 "${auth[@]}" "${api}?ref=${BRANCH}" | jq -r '.sha // empty')"

# base64 the content; strip newlines GNU base64 wraps in (the API wants one blob).
b64="$(printf '%s' "$content" | base64 | tr -d '\n')"

body="$(jq -n --arg m "$commit_msg" --arg c "$b64" --arg br "$BRANCH" \
  --arg an "$AUTHOR_NAME" --arg ae "$AUTHOR_EMAIL" --arg sha "$sha" \
  '{message: $m, content: $c, branch: $br,
    author: {name: $an, email: $ae}, committer: {name: $an, email: $ae}}
   + (if $sha == "" then {} else {sha: $sha} end)')"

curl -fsS --max-time 30 -X PUT "${auth[@]}" "$api" -d "$body" >/dev/null
