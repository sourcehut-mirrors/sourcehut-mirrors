# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the `sourcehut-mirrors` GitHub organization's control repo. It mirrors a fixed list of
SourceHut (`git.sr.ht`) repositories to GitHub, one GitHub repo per mirrored project, with
documented permission from both the upstream project owners and SourceHut. It is not sponsored,
endorsed, or affiliated with SourceHut. There is no application code — the repo is config
(`repos.txt`), two small scripts, and a GitHub Actions workflow.

## Architecture

The workflow (`.github/workflows/mirror.yml`) runs as three jobs, so that a single broken or
deleted upstream repo can't stall or fail the whole run:

1. **`plan`** — runs `scripts/gen-matrix.py repos.txt`, which parses the config file and emits a
   GitHub Actions matrix (`{owner, repo, github_repo}` per line) as a job output. Fails the whole
   run immediately, with a line-numbered error, on a malformed config (bad field count, invalid
   GitHub repo name, or a duplicate source/destination) — this is deliberately the only place a
   config mistake is fatal.
2. **`mirror`** — a matrix job, one runner per repo (`fail-fast: false`, `max-parallel: 8`), each
   running `scripts/mirror-one.sh <owner> <repo> <github_repo>`. This is what actually does `git
   clone --mirror` / `git fetch --prune --prune-tags` from `https://git.sr.ht/~<owner>/<repo>`
   followed by `git push --mirror` to `https://github.com/sourcehut-mirrors/<github_repo>.git`,
   authenticated with the `GH_MIRROR_TOKEN` secret. Each matrix leg has its own
   `actions/cache` entry keyed on `github_repo` (not one shared blob for all repos), so an
   unrelated repo's first clone or an unrelated config change no longer invalidates every mirror's
   cache.
3. **`badge`** — runs `if: always()` after `mirror`, regardless of per-repo outcome, and publishes
   a Shields.io "last mirror" JSON badge to the `gh-pages` branch (displayed in `README.md`),
   colored green if every matrix leg succeeded and red otherwise.

`scripts/mirror-one.sh` is the resilience layer and is worth reading in full before touching it.
Per repo, it:
- Retries clone/fetch/push up to 3 times with backoff (10s, 30s), each attempt bounded by a
  5-minute `timeout` and a stalled-transfer abort (`http.lowSpeedLimit`/`http.lowSpeedTime`), so
  one hung connection can't eat the whole job.
- Treats an upstream 404 (`repository '...' not found`) as a graceful skip (exit 0, leaves any
  existing mirror untouched) rather than a failure — expected when an upstream repo is
  temporarily down or has been deleted.
- Detects a corrupted local cache (bad/missing objects) and self-heals by discarding it and
  re-cloning, versus a plain transient fetch failure, where it leaves the cache alone so the next
  scheduled run can retry from where it left off.
- Best-effort syncs the local bare repo's `HEAD` to match upstream's default branch before
  pushing, so a renamed default branch (e.g. `master` -> `main`) carries through. Regular branch
  renames/deletes need no special handling: `fetch --prune --prune-tags` + `push --mirror` already
  force-update and delete refs to match upstream exactly.
- `GIT_TERMINAL_PROMPT=0` ensures a bad URL/credential fails fast instead of hanging on a prompt.

`repos/` (workflow-cache only, restored per matrix leg) holds the bare mirror clone between runs.
It will not exist in a fresh local checkout.

## `repos.txt` format

One mirror per line: `<sourcehut-owner> <sourcehut-repo> [github-repo]`, fields separated by any
amount of whitespace so columns can be space-aligned. `github-repo` is optional and defaults to
`sourcehut-repo`; set it explicitly only when the desired GitHub repo name should differ. `#`
starts a comment; blank lines are ignored.

## Adding, removing, or renaming a mirror

Edit `repos.txt` directly — this is the only place mirror configuration lives. Removing a line
stops future syncs but does not delete the already-created GitHub repo; past removals (e.g.
`Remove ~fijarom/stutui`) have been handled as separate manual repo deletions on GitHub. Adding a
line requires the destination `sourcehut-mirrors/<github-repo>` GitHub repo to already exist and
be empty — `git push --mirror` doesn't create repos, and `mirror-one.sh` will fail loudly (not
skip) if the destination is missing. New mirror requests come in as GitHub issues on this repo.

## Pushing to origin

This repo can only be pushed to GitHub using the SSH key at `~/.ssh/sourcehut-mirrors` — the
default SSH key does not have write access. Either point this repo's git config at it:

```
git config core.sshCommand "ssh -i ~/.ssh/sourcehut-mirrors -o IdentitiesOnly=yes"
```

or set it per-command via `GIT_SSH_COMMAND`:

```
GIT_SSH_COMMAND="ssh -i ~/.ssh/sourcehut-mirrors -o IdentitiesOnly=yes" git push
```

## Running locally

```
python3 scripts/gen-matrix.py repos.txt          # validate/preview the matrix
GH_MIRROR_TOKEN=<token> scripts/mirror-one.sh <owner> <repo> [github-repo]
```

Both are stdlib/POSIX-only (no dependencies to install). `scripts/mirror-one.sh` requires `git`
and GNU coreutils' `timeout` on `PATH` — present by default on the `ubuntu-latest` runner this
workflow targets, but not on macOS, so local runs there need a `timeout` shim (e.g. `brew install
coreutils` and alias `gtimeout`) or GH Actions itself to test against. Run from the repo root; the
script creates `repos/<github-repo>` relative to the current directory. There are no tests,
linter, or build step in this repo.
