#!/usr/bin/env bash
# Deploy the HuffmanStacks coming-soon to whatever ACTUALLY serves
# huffmanstacks.com. It finds the real docroot deterministically by locating the
# live page's own text on disk (host dirs + docker bind-mounts/named volumes) and,
# if needed, inside running containers. Works whether the server is host-nginx,
# an nginx/caddy container, or a mounted volume. Static files go live on copy, so
# no service reload is required (that is why the masked-nginx reload no longer
# matters). Safe by design: backs up first, copies over (no deletes), reversible.
set -uo pipefail

REPO="https://github.com/HuffmanStacks/huffmanstacks-coming-soon.git"
SIG_OLD="Software, systems, and automation"   # unique to the OLD (blue) live page
SIG_NEW="Something refined"                    # unique to the NEW (gold) page
# Host roots to scan. /var/lib/docker/volumes covers container bind-mounts/volumes.
SEARCH_DIRS="/var/www /opt /srv /usr/share/nginx /usr/share/caddy /var/lib/docker/volumes /etc/nginx"
TS="$(date +%Y%m%d-%H%M%S)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 "$REPO" "$TMP/r" >/dev/null 2>&1 || { echo "FAIL: git clone"; exit 1; }
SITE="$TMP/r"; rm -rf "$SITE/_deploy" "$SITE/.git"

ROOT="${HS_DOCROOT:-}"        # host path to deploy into (if known)
SERVING_CT=""; CT_DIR=""      # set only if the page lives inside a container fs

# ---- 1. Find the live page by its content on the host filesystem -------------
if [ -z "$ROOT" ]; then
  hit="$(grep -rlF "$SIG_OLD" $SEARCH_DIRS 2>/dev/null --include='*.html' | head -1)"
  if [ -z "$hit" ]; then
    hit="$(grep -rlF "$SIG_NEW" $SEARCH_DIRS 2>/dev/null --include='*.html' \
            | grep -v '^/var/www/html/' | head -1)"   # skip the earlier decoy deploy
  fi
  if [ -n "$hit" ]; then ROOT="$(dirname "$hit")"; echo "DISCOVERY: real docroot by content = $ROOT"; fi
fi

# ---- 2. Search inside running containers (image/overlay, not just mounts) -----
if [ -z "$ROOT" ] && command -v docker >/dev/null 2>&1; then
  for c in $(docker ps -q 2>/dev/null); do
    f="$(docker exec "$c" sh -c "grep -rlF '$SIG_OLD' /usr/share/nginx/html /srv /var/www /usr/share/caddy /app /site 2>/dev/null | head -1" 2>/dev/null)"
    [ -z "$f" ] && continue
    SERVING_CT="$c"; CT_DIR="$(dirname "$f")"
    echo "DISCOVERY: live page inside container $c at $CT_DIR"
    # Try to map the container dir back to a host bind-mount so we can copy on host.
    ROOT="$(docker inspect "$c" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null \
            | awk -F'|' -v d="$CT_DIR" '$1==d || index(d, $1"/")==1 {print $2; exit}')"
    [ -n "$ROOT" ] && echo "  mapped to host path: $ROOT" || echo "  no host mount — will deploy via docker cp"
    break
  done
fi

# ---- 3. Host nginx default_server root (last resort) -------------------------
if [ -z "$ROOT" ] && [ -z "$SERVING_CT" ]; then
  ROOT="$(nginx -T 2>/dev/null | awk '
    /server[[:space:]]*\{/ { depth++; if (depth==1){buf=""; cap=1} }
    cap { buf=buf"\n"$0 }
    /\}/ { if (cap){ depth--; if (depth==0){
             if (buf ~ /listen[^;]*default_server/ && match(buf,/[^a-z_]root[[:space:]]+[^;]+;/)){
               r=substr(buf,RSTART,RLENGTH); gsub(/root|[[:space:]]|;/,"",r); print r; exit }
             cap=0 } } }')"
  [ -n "$ROOT" ] && echo "DISCOVERY: falling back to nginx default_server root = $ROOT"
fi

# ---- Always log a full environment snapshot (so any miss is fully diagnosable) ----
echo "----- ENV SNAPSHOT $(date -Is) -----"
echo "## listening on 80/443:"; ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' || echo "  (none seen)"
if command -v docker >/dev/null 2>&1; then
  echo "## docker ps:"; docker ps --format '  {{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null || true
  echo "## web-container mounts:"
  for c in $(docker ps -q 2>/dev/null); do
    docker inspect "$c" --format '  '"$c"': {{range .Mounts}}{{.Source}}=>{{.Destination}} {{end}}' 2>/dev/null
  done
else
  echo "## docker: not installed"
fi
echo "-------------------------------------"

# ---- Abort cleanly if nothing found -----------------------------------------
if [ -z "$ROOT" ] && [ -z "$SERVING_CT" ]; then
  echo "COULD NOT locate the real docroot. Read the ENV SNAPSHOT above. Aborting (nothing changed)."
  exit 2
fi

# ---- Deploy: host path mode -------------------------------------------------
if [ -n "$ROOT" ]; then
  echo "TARGET DOCROOT (host): $ROOT"
  mkdir -p "$ROOT"
  BK="/root/huffmanstacks-docroot-backup-$TS.tgz"
  tar -czf "$BK" -C "$ROOT" . 2>/dev/null && echo "BACKUP: $BK" || echo "BACKUP: (docroot was empty)"
  cp -a "$SITE/." "$ROOT/"
  chmod -R a+rX "$ROOT" 2>/dev/null || true

# ---- Deploy: container-internal mode (no host mount) ------------------------
else
  echo "TARGET DOCROOT (container $SERVING_CT): $CT_DIR"
  BK="/root/huffmanstacks-docroot-backup-$TS.tgz"
  docker cp "$SERVING_CT:$CT_DIR" "$TMP/backup" 2>/dev/null \
    && tar -czf "$BK" -C "$TMP/backup" . 2>/dev/null && echo "BACKUP: $BK" || echo "BACKUP: (could not snapshot container dir)"
  ( cd "$SITE" && for p in *; do docker cp "$p" "$SERVING_CT:$CT_DIR/"; done )
fi

# ---- Verify (static files are live immediately; no reload needed) ------------
echo "===== VERIFY ====="
echo -n "HTTP: ";          curl -sI https://huffmanstacks.com/ | head -1
echo -n "is coming-soon: "; curl -s https://huffmanstacks.com/ | grep -q "$SIG_NEW" && echo YES || echo NO
echo "DONE."
