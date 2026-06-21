#!/usr/bin/env bash
# Deploy the HuffmanStacks coming-soon into the EXISTING huffmanstacks.com docroot.
# Safe by design: backs up first, copies over (no deletions), reuses the existing
# nginx vhost, validates config before reload. Touches nothing mail-related.
set -uo pipefail
REPO="https://github.com/HuffmanStacks/huffmanstacks-coming-soon.git"
TMP="$(mktemp -d)"
git clone --depth 1 "$REPO" "$TMP/r" >/dev/null 2>&1 || { echo "FAIL: git clone"; exit 1; }
SITE="$TMP/r"; rm -rf "$SITE/_deploy" "$SITE/.git"

# Determine the docroot that serves huffmanstacks.com (plural). Priority:
#   1) explicit override   HS_DOCROOT=/path
#   2) a vhost whose server_name matches huffmanstacks.com (if one exists)
#   3) the default_server root — what an unmatched host like huffmanstacks.com
#      actually hits. This box has NO plural vhost; it falls through to default.
ROOT="${HS_DOCROOT:-}"

if [ -z "$ROOT" ]; then
  ROOT="$(nginx -T 2>/dev/null | awk '
    /server[[:space:]]*\{/ { depth++; if (depth==1){buf=""; cap=1} }
    cap { buf=buf"\n"$0 }
    /\}/ { if (cap){ depth--; if (depth==0){
             if (buf ~ /server_name[^;]*[^a-z]huffmanstacks\.com/ && match(buf,/[^a-z_]root[[:space:]]+[^;]+;/)){
               r=substr(buf,RSTART,RLENGTH); gsub(/root|[[:space:]]|;/,"",r); print r; exit }
             cap=0 } } }')"
fi

if [ -z "$ROOT" ]; then
  # Fallback: docroot of the default_server (catch-all for unmatched hostnames).
  ROOT="$(nginx -T 2>/dev/null | awk '
    /server[[:space:]]*\{/ { depth++; if (depth==1){buf=""; cap=1} }
    cap { buf=buf"\n"$0 }
    /\}/ { if (cap){ depth--; if (depth==0){
             if (buf ~ /listen[^;]*default_server/ && match(buf,/[^a-z_]root[[:space:]]+[^;]+;/)){
               r=substr(buf,RSTART,RLENGTH); gsub(/root|[[:space:]]|;/,"",r); print r; exit }
             cap=0 } } }')"
  [ -n "$ROOT" ] && echo "NOTE: no huffmanstacks.com vhost found — using the default_server root."
fi

if [ -z "${ROOT:-}" ]; then
  echo "COULD NOT auto-detect a docroot from nginx."
  echo "Set HS_DOCROOT=/path explicitly, or run _deploy/inspect.sh. Aborting (nothing changed)."
  exit 2
fi
echo "TARGET DOCROOT: $ROOT"

mkdir -p "$ROOT"
TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/huffmanstacks-docroot-backup-$TS.tgz"
tar -czf "$BK" -C "$ROOT" . 2>/dev/null && echo "BACKUP: $BK" || echo "BACKUP: (docroot was empty)"

cp -a "$SITE/." "$ROOT/"
chown -R www-data:www-data "$ROOT" 2>/dev/null || true

if nginx -t 2>/dev/null; then systemctl reload nginx && echo "nginx reloaded"; else echo "nginx -t FAILED — NOT reloading"; fi

echo "===== VERIFY ====="
echo -n "HTTP: "; curl -sI https://huffmanstacks.com/ | head -1
echo "robots.txt:"; curl -s https://huffmanstacks.com/robots.txt | sed -n '1,4p'
echo -n "is coming-soon: "; curl -s https://huffmanstacks.com/ | grep -q 'Something refined' && echo YES || echo NO
echo "DONE -> deployed to $ROOT (backup at $BK)"
