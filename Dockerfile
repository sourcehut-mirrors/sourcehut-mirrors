# Small, self-contained image that runs the staggered mirror loop.
# Everything the scripts need: bash (arrays/here-strings), git, curl, jq,
# GNU coreutils (timeout/sleep with duration suffixes), python3 (gen-matrix),
# tini (proper PID 1 / signal reaping), CA certs for TLS to git.sr.ht/github.
FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      git \
      curl \
      jq \
      coreutils \
      python3 \
      tini \
      ca-certificates

WORKDIR /app

# Only the code goes in the image; repos.txt is also baked in but is meant to
# be bind-mounted read-only (see compose.yaml) so the list can change without
# a rebuild. State and the bare-clone cache live on the /data volume instead.
COPY scripts/ ./scripts/
COPY repos.txt ./repos.txt
COPY docker/entrypoint.sh /usr/local/bin/mirror-loop

# Persistent working files go on the volume, not the read-only-ish /app layer.
# REPOS_URL: poll GitHub's raw repos.txt each tick so pushing to master updates
# the running server (set REPOS_URL="" to pin to the baked-in copy instead).
ENV MIRROR_STATE_FILE=/data/.mirror-state \
    MIRROR_LOCK_FILE=/data/.mirror.lock \
    MIRROR_CACHE_DIR=/data/repos \
    MIRROR_INTERVAL=18m \
    REPOS_FILE=/data/repos.txt \
    REPOS_URL=https://raw.githubusercontent.com/sourcehut-mirrors/sourcehut-mirrors/master/repos.txt \
    HOME=/tmp

# Per-tick status badge + uptime commit on gh-pages (set BADGE_BRANCH= to
# disable). Author email must be verified on the GitHub account for the commits
# to count as contributions.
ENV BADGE_BRANCH=gh-pages \
    BADGE_REPO=sourcehut-mirrors/sourcehut-mirrors \
    BADGE_PATH=badge/last-mirror.json \
    BADGE_AUTHOR_NAME=sourcehut-mirrors \
    BADGE_AUTHOR_EMAIL=sourcehut-mirrors@pm.me

RUN chmod +x /usr/local/bin/mirror-loop scripts/*.sh scripts/*.py \
 && addgroup -S mirror \
 && adduser -S -G mirror mirror \
 && mkdir -p /data \
 && chown mirror:mirror /data

VOLUME ["/data"]
USER mirror

# tini reaps the short-lived git/curl children and forwards signals so
# `docker stop` ends the loop cleanly.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/mirror-loop"]
