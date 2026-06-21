#!/usr/bin/env bash
# HuffmanStacks coming-soon — ongoing auto-deploy (pull model, server-side).
# Runs on the VPS via a systemd timer. Cheaply asks GitHub for the latest commit
# on main; ONLY when it changed does it invoke the existing safe _deploy/go.sh
# (backup -> copy -> nginx -t -> reload). Idempotent, locked, logged, self-pruning.
# Nothing leaves the box; no secrets; no third party ever holds VPS access.
set -uo pipefail

REPO="https://github.com/HuffmanStacks/huffmanstacks-coming-soon.git"
BRANCH="main"
STATE="/var/lib/hs-coming-soon/last-sha"
LOG="/var/log/hs-coming-soon-deploy.log"
LOCK="/var/lock/hs-coming-soon-deploy.lock"
KEEP_BACKUPS=10

mkdir -p "$(dirname "$STATE")"
log() { echo "$(date -Is) $*" >>"$LOG"; }

# Prevent overlapping runs (a slow deploy must not collide with the next tick).
exec 9>"$LOCK"
if ! flock -n 9; then
  log "skip: previous run still holding lock"
  exit 0
fi

# Cheap remote check — no clone, just the ref's SHA.
REMOTE_SHA="$(git ls-remote "$REPO" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')"
if [ -z "$REMOTE_SHA" ]; then
  log "ERROR: could not reach GitHub (git ls-remote failed) — will retry next tick"
  exit 1
fi

LAST_SHA="$(cat "$STATE" 2>/dev/null || echo none)"
if [ "$REMOTE_SHA" = "$LAST_SHA" ]; then
  exit 0   # no change — stay quiet, no log spam
fi

log "change detected: ${LAST_SHA:0:12} -> ${REMOTE_SHA:0:12} — deploying"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! git clone --depth 1 -b "$BRANCH" "$REPO" "$TMP/r" >>"$LOG" 2>&1; then
  log "ERROR: git clone failed — NOT advancing state, will retry next tick"
  exit 1
fi

# Hand off to the tested, safe deploy script that ships in the repo.
if bash "$TMP/r/_deploy/go.sh" >>"$LOG" 2>&1; then
  echo "$REMOTE_SHA" > "$STATE"
  log "deploy OK at ${REMOTE_SHA:0:12}"
  # Keep only the newest N docroot backups go.sh wrote to /root/.
  ls -1t /root/huffmanstacks-docroot-backup-*.tgz 2>/dev/null \
    | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
  log "backups pruned (kept newest $KEEP_BACKUPS)"
else
  log "ERROR: go.sh failed — state NOT advanced, will retry next tick"
  exit 1
fi
