# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the `sourcehut-mirrors` GitHub organization's control repo. It mirrors a fixed list of
SourceHut (`git.sr.ht`) repositories to GitHub, one GitHub repo per mirrored project. It is not
sponsored, endorsed, or affiliated with SourceHut. There is no application code — the entire repo
is a single Python script plus a GitHub Actions workflow that runs it on a schedule.

## Architecture

- `mirror.py` — the whole implementation. `REPOS` is a list of `(sourcehut_owner, sourcehut_repo,
  github_repo_name)` tuples. For each entry it does a `git clone --mirror` (first run) or `git
  fetch -p origin` (subsequent runs) from `https://git.sr.ht/~<owner>/<repo>` into `repos/<repo>`,
  then `git push --mirror` to `https://github.com/sourcehut-mirrors/<github_repo_name>.git` using
  the `GH_MIRROR_TOKEN` token. Non-fatal command failures (e.g. a SourceHut repo being temporarily
  unavailable) are logged as GitHub Actions warnings and don't abort the whole run; fatal ones
  (e.g. the push itself failing) exit non-zero.
- `.github/workflows/mirror.yml` — runs `mirror.py` daily (`cron: '0 0 * * *'`), on push to
  `master`, and on manual dispatch. It caches the `repos/` directory (keyed on the hash of
  `mirror.py`) across runs so mirrors are incremental fetches rather than full re-clones, then
  generates a Shields.io "last mirror" badge JSON file and publishes it to the `gh-pages` branch
  (displayed in `README.md`).
- `repos/` (git-ignored, workflow-cache only) — holds the bare mirror clones between CI runs. It
  will not exist in a fresh local checkout.

## Adding, removing, or renaming a mirror

Edit the `REPOS` list in `mirror.py` directly — this is the only place mirror configuration lives.
Each entry is `(sourcehut_owner, sourcehut_repo_name, github_repo_name)`; the third element only
needs to differ from the second when the desired GitHub repo name differs from the SourceHut one.
Removing an entry stops future syncs but does not delete the already-created GitHub repo — commit
history shows that removals (e.g. `Remove ~fijarom/stutui`) are handled as separate manual repo
deletions on GitHub. New mirror requests come in as GitHub issues on this repo.

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
GH_MIRROR_TOKEN=<token with push access to the sourcehut-mirrors org> python3 mirror.py
```

Requires `git` on `PATH`. Run from the repo root (the script `chdir`s to its own directory and
creates `repos/` there). There are no tests, linter, or build step in this repo.
