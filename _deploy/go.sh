#!/usr/bin/env bash
# Deploy the HuffmanStacks coming-soon into the EXISTING huffmanstacks.com docroot.
# Safe by design: backs up first, copies over (no deletions), reuses the existing
# nginx vhost, validates config before reload. Touches nothing mail-related.
set -uo pipefail
REPO="https://github.com/HuffmanStacks/huffmanstacks-coming-soon.git"
TMP="$(mktemp -d)"
git clone --depth 1 "$REPO" "$TMP/r" >/dev/null 2>&1 || { echo "FAIL: git clone"; exit 1; }
SITE="$TMP/r"; rm -rf "$SITE/_deploy" "$SITE/.git"

# Discover the docroot of the huffmanstacks.com (plural) vhost from running nginx.
ROOT="$(nginx -T 2>/dev/null | awk '
  /server[[:space:]]*\{/ { depth++; if (depth==1){buf=""; cap=1} }
  cap { buf=buf"\n"$0 }
  /\}/ { if (cap){ depth--; if (depth==0){
           if (buf ~ /server_name[^;]*[^a-z]huffmanstacks\.com/ && match(buf,/[^a-z_]root[[:space:]]+[^;]+;/)){
             r=substr(buf,RSTART,RLENGTH); gsub(/root|[[:space:]]|;/,"",r); print r; exit }
           cap=0 } } }')"

if [ -z "${ROOT:-}" ]; then
  echo "COULD NOT auto-detect the huffmanstacks.com docroot from nginx."
  echo "Run _deploy/inspect.sh first and tell Claude the docroot. Aborting (nothing changed)."
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
