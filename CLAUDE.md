# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the `sourcehut-mirrors` GitHub organization's control repo. It mirrors a fixed list of
SourceHut (`git.sr.ht`) repositories to GitHub, one GitHub repo per mirrored project, with
documented permission from both the upstream project owners and SourceHut. It is not sponsored,
endorsed, or affiliated with SourceHut. There is no application code — the repo is config
(`repos.txt`), three small scripts under `scripts/`, and a `Dockerfile` + `compose.yaml` that run
them as a container.

The mirror runs as a **Docker container**: a long-lived loop that mirrors one repo, sleeps, and
repeats, walking `repos.txt` one repo at a time so `git.sr.ht` is never hit by a parallel burst of
clones. There is intentionally no CI: an earlier GitHub Actions workflow that fanned the mirror out
as a parallel matrix (and updated a "last mirror" badge via `gh-pages`) was removed in favor of
this. If you reintroduce automation, keep it one-clone-at-a-time.

## Architecture

Three scripts, driven each tick by the container's loop (`docker/entrypoint.sh`, PID 1 under
tini); see "Deployment" below:

1. **`scripts/gen-matrix.py`** parses and validates `repos.txt`, emitting the entries as a JSON
   object (`{"repos": [{owner, repo, github_repo}, …]}`) on stdout. It exits non-zero with a
   line-numbered `::error::` on a malformed config (bad field count, invalid GitHub repo name, or a
   duplicate source/destination) — the single place a config mistake is fatal, so a bad line aborts
   the tick instead of getting mirrored. (The name is a holdover from when it fed a GitHub Actions
   matrix; it's now just the parser/validator.)
2. **`scripts/mirror-next.sh`** is what the loop calls each tick. Each invocation mirrors exactly
   **one** repo, rotating round-robin through the `gen-matrix.py` output via a pointer file
   (`MIRROR_STATE_FILE`, on the `/data` volume in the container). Calling it every `INTERVAL`
   refreshes each of the N repos once every `INTERVAL * N`, with only ever one clone/fetch in
   flight — this is the whole point, versus a parallel fan-out that hammers `git.sr.ht`. Rotation
   uses the stored pointer, **not** a clock-derived index, so a late or skipped tick resumes in
   order rather than silently skipping a repo; the pointer advances *before* mirroring, so a failing
   repo isn't retried in a tight loop — it comes back around next full cycle. The built-in loop is
   sequential so ticks can't overlap; when driven instead by an external scheduler (`MIRROR_ONCE=1`
   from cron/k8s), `flock` on `MIRROR_LOCK_FILE` guards against overlap if `flock` is installed
   (it's optional — the script no-ops the lock when absent, as in the image). `MIRROR_DRY_RUN=1`
   prints the selected repo and advances the pointer without mirroring, for eyeballing the rotation.
3. **`scripts/mirror-one.sh`** is the resilience layer that actually mirrors the one repo it's
   handed: `git clone --mirror` / `git fetch --prune --prune-tags` from
   `https://git.sr.ht/~<owner>/<repo>`, then `git push --mirror` to
   `https://github.com/sourcehut-mirrors/<github_repo>.git`, authenticated with `GH_MIRROR_TOKEN`.
   It's worth reading in full before touching it. Per repo, it:

- Retries clone/fetch/push up to 3 times with backoff (10s, 30s), each attempt bounded by a
  5-minute `timeout` and a stalled-transfer abort (`http.lowSpeedLimit`/`http.lowSpeedTime`), so
  one hung connection can't eat the tick.
- Treats an upstream 404 (`repository '...' not found`) as terminal: fails (exit 1) without wasting
  the retry budget on a deterministic outcome that retrying can't change, and leaves any existing
  GitHub mirror untouched rather than deleting it. Because each tick mirrors a single repo, this is
  isolated — the next tick moves on to the next repo and this one comes back around next cycle. A
  repo failing here is either genuinely gone upstream (remove it from `repos.txt`) or temporarily
  unreachable (next cycle retries from scratch).
- Detects a corrupted local cache (bad/missing objects) and self-heals by discarding it and
  re-cloning, versus a plain transient fetch failure, where it leaves the cache alone so the next
  tick can retry from where it left off.
- Best-effort syncs the local bare repo's `HEAD`, and GitHub's configured default branch (via the
  GitHub API, using `GH_MIRROR_TOKEN`), to match upstream's default branch before pushing. This
  matters beyond cosmetics: GitHub refuses to let `push --mirror` delete whatever branch is
  currently set as the repo's default, so if upstream renames its default branch (old one deleted,
  new one created), the push fails on that one ref *every run*, not just transiently, until
  GitHub's default branch setting is repointed away from the now-deleted branch. The sync runs
  proactively before the push and again reactively (with one retry) if the push is rejected with
  "refusing to delete the current branch" — this exact failure mode hit `arm-assembly-intro` in
  production, where GitHub's default branch was stuck on a deleted `dev` after upstream moved to
  `master`. Requires `GH_MIRROR_TOKEN` to have permission to edit repo settings (Administration:
  write for fine-grained PATs, or `repo` scope for classic ones); if it doesn't, the sync
  no-ops with a warning and the underlying push failure surfaces instead. Regular (non-default)
  branch renames/deletes need no special handling: `fetch --prune --prune-tags` + `push --mirror`
  already force-update and delete refs to match upstream exactly.
- `GIT_TERMINAL_PROMPT=0` ensures a bad URL/credential fails fast instead of hanging on a prompt.

The bare mirror clones are cached between ticks, one directory per `github-repo`, under
`MIRROR_CACHE_DIR` (default `repos/` next to the cwd for local runs; `/data/repos` on the volume in
the container). Git-ignored; won't exist in a fresh checkout.

## `repos.txt` format

One mirror per line: `<sourcehut-owner> <sourcehut-repo> [github-repo]`, fields separated by any
amount of whitespace so columns can be space-aligned. `github-repo` is optional and defaults to
`sourcehut-repo`; set it explicitly only when the desired GitHub repo name should differ. `#`
starts a comment; blank lines are ignored.

## Adding, removing, or renaming a mirror

Edit `repos.txt` directly and push to `master` — this is the only place mirror configuration
lives, and the running container polls it from GitHub (see "Deployment"), so a push is all it takes
to reconfigure the server. Removing a line stops future syncs but does not delete the
already-created GitHub repo; past removals (e.g.
`Remove ~fijarom/stutui`) have been handled as separate manual repo deletions on GitHub. Adding a
line requires the destination `sourcehut-mirrors/<github-repo>` GitHub repo to already exist and
be empty — `git push --mirror` doesn't create repos, and `mirror-one.sh` will fail loudly (not
skip) if the destination is missing. New mirror requests come in as GitHub issues on this repo.

## Deployment

Docker (via `compose.yaml`) is the intended way to run it:

```
cp .env.example .env      # then edit in the real GH_MIRROR_TOKEN
docker compose up -d --build
docker compose logs -f
```

- **`.env`** holds `GH_MIRROR_TOKEN` (required) and an optional `MIRROR_INTERVAL`; it's
  git-ignored. `.env.example` documents the token scopes.
- **`MIRROR_INTERVAL`** is the sleep between ticks (any GNU `sleep` duration: `18m`, `3m`, `1h`).
  Each repo refreshes about every `MIRROR_INTERVAL * N` (N = lines in `repos.txt`), so set it to
  `target-refresh / N` — default `18m` gives ~6h per repo at N=20; `3m` gives hourly. **Retune it
  when `repos.txt` grows or shrinks.**
- The `mirror-data` named volume (`/data`) holds the rotation pointer, the polled `repos.txt`, and
  the bare-clone cache, so restarts and rebuilds resume where they left off.
- **`repos.txt` is polled from GitHub each tick** (`REPOS_URL`, default this repo's raw `master`),
  so pushing a change to `master` updates the running server on the next tick — no rebuild, no
  redeploy, nothing to touch on the box. The fetched file is validated with `gen-matrix.py` before
  it replaces the working copy, so a malformed commit is rejected (logged, last good copy kept)
  instead of halting the mirror; a network blip likewise keeps the last copy. Set `REPOS_URL=` (empty)
  in `.env` to pin to the image's baked-in list instead. The scripts themselves are baked in, so
  changing *them* still needs a `--build`.
- The image runs one repo at a time in a loop, so it never overlaps itself. To drive it from an
  external scheduler instead (host cron, k8s CronJob), run the image with `-e MIRROR_ONCE=1` to do
  a single tick and exit.

Image internals: Alpine + `bash git curl jq coreutils python3 tini ca-certificates`, running as a
non-root `mirror` user. `MIRROR_STATE_FILE`, `MIRROR_LOCK_FILE`, and `MIRROR_CACHE_DIR` are set to
`/data/...` in the `Dockerfile` so all writable state stays on the volume.

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
python3 scripts/gen-matrix.py repos.txt                            # validate/preview the parsed config
GH_MIRROR_TOKEN=<token> MIRROR_DRY_RUN=1 scripts/mirror-next.sh    # show which repo is next, don't mirror
GH_MIRROR_TOKEN=<token> scripts/mirror-next.sh                     # mirror the next repo in rotation
GH_MIRROR_TOKEN=<token> scripts/mirror-one.sh <owner> <repo> [github-repo]   # mirror one specific repo
```

The scripts are stdlib/POSIX-only (no dependencies to install). `mirror-one.sh` — and therefore
`mirror-next.sh` — requires `git`, `curl`, `jq`, and GNU coreutils' `timeout` on `PATH`. `timeout`
isn't on macOS, so local runs there need a shim (e.g. `brew install coreutils` and alias
`gtimeout`) — or just run a single tick in the container, which has everything:

```
docker compose run --rm -e MIRROR_ONCE=1 mirror
```

Run directly from the repo root; the scripts create `repos/<github-repo>` and the
`.mirror-state`/`.mirror.lock` files relative to the current directory (override via
`MIRROR_CACHE_DIR` / `MIRROR_STATE_FILE` / `MIRROR_LOCK_FILE`). There are no tests, linter, or build
step in this repo.
