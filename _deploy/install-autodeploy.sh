#!/usr/bin/env bash
# ONE-TIME installer — run once on the VPS as root. Wires the pull-cron auto-deploy.
# Re-runnable safely (idempotent). Also triggers an immediate first deploy.
set -euo pipefail

REPO="https://github.com/HuffmanStacks/huffmanstacks-coming-soon.git"
DEST="/opt/hs-coming-soon"

echo "==> Fetching latest deploy scripts from GitHub"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 "$REPO" "$TMP/r"

echo "==> Installing wrapper to $DEST"
mkdir -p "$DEST" /var/lib/hs-coming-soon
install -m 0755 "$TMP/r/_deploy/auto-deploy.sh" "$DEST/auto-deploy.sh"

echo "==> Installing systemd units"
install -m 0644 "$TMP/r/_deploy/systemd/hs-coming-soon-deploy.service" /etc/systemd/system/
install -m 0644 "$TMP/r/_deploy/systemd/hs-coming-soon-deploy.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now hs-coming-soon-deploy.timer

echo "==> Triggering an immediate first deploy"
systemctl start hs-coming-soon-deploy.service || true

echo
echo "==> Timer schedule:"
systemctl list-timers hs-coming-soon-deploy.timer --no-pager || true
echo
echo "==> Recent log:"
tail -n 20 /var/log/hs-coming-soon-deploy.log 2>/dev/null || echo "(no log yet)"
echo
echo "DONE. The VPS now checks GitHub every 5 min and auto-deploys on change."
echo "Watch live:   journalctl -u hs-coming-soon-deploy.service -f"
echo "Or the log:   tail -f /var/log/hs-coming-soon-deploy.log"
echo "Disable:      systemctl disable --now hs-coming-soon-deploy.timer"
