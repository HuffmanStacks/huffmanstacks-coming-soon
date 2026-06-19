#!/usr/bin/env bash
# READ-ONLY. Shows how huffmanstacks.com is currently served. Changes nothing.
echo "===== HuffmanStacks deploy INSPECT (read-only) ====="
echo
echo "--- nginx config files referencing huffmanstacks.com ---"
grep -rilE 'huffmanstacks\.com' /etc/nginx 2>/dev/null
echo
echo "--- those vhost files (full) ---"
for f in $(grep -rilE 'huffmanstacks\.com' /etc/nginx 2>/dev/null); do
  echo "########## $f ##########"
  cat "$f"
  echo
done
echo "--- effective server_name + root + listen (nginx -T) ---"
nginx -T 2>/dev/null | grep -nE 'server_name|[[:space:]]root |listen '
echo
echo "--- /var/www contents ---"
ls -la /var/www 2>/dev/null
echo
echo "===== end inspect (nothing was changed) ====="
