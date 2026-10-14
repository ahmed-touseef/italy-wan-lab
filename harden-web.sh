#!/usr/bin/env bash
# Hardens the status page at https://wan.touseefahmed.com. Safe to run again.
#   ./harden-web.sh           apply the settings, then check them from outside
#   ./harden-web.sh --apply   apply only (publish.sh uses this before HTTPS exists)
#   ./harden-web.sh --check   check only
# Applying installs web/security.conf and web/limits.conf, points the site at them and
# hides the Nginx version (that one line in nginx.conf covers every site on the server;
# nothing else about other sites changes). If Nginx rejects the result, every file is
# put back as it was and the running site is never touched.
set -euo pipefail
cd "$(dirname "$0")"
DOMAIN=wan.touseefahmed.com
SITE=/etc/nginx/sites-available/$DOMAIN
SNIP=/etc/nginx/snippets/italy-wan-security.conf
LIMITS=/etc/nginx/conf.d/italy-wan-limits.conf
MAIN=/etc/nginx/nginx.conf
MODE=${1:-all}

apply() {
  [ -f "$SITE" ] || { echo "No Nginx site for $DOMAIN yet: run ./publish.sh first"; exit 1; }
  BAK=$(mktemp -d)
  trap 'rm -rf "$BAK"' EXIT
  for f in "$SITE" "$SNIP" "$LIMITS" "$MAIN"; do
    if [ -f "$f" ]; then sudo cp -a "$f" "$BAK/"; fi
  done

  echo "== Security settings =="
  sudo install -d -m 755 /etc/nginx/snippets /etc/nginx/conf.d
  sudo install -m 644 web/security.conf "$SNIP"
  sudo install -m 644 web/limits.conf "$LIMITS"
  echo "  installed $SNIP"
  echo "  installed $LIMITS"

  # Older copies of the site set four headers themselves: swap them for the shared file.
  sudo python3 - "$SITE" "$SNIP" <<'PY'
import re, sys
path, snip = sys.argv[1:]
s = open(path).read()
old = re.compile(r"^[ \t]*add_header[ \t]+(X-Content-Type-Options|Referrer-Policy|X-Frame-Options|Content-Security-Policy)[ \t].*\n", re.M)
if snip not in s:
    at = old.search(s) or re.search(r"^[ \t]*index[ \t]+index\.html;\n", s, re.M)
    if not at:
        sys.exit("  could not find where to add the settings in " + path + "; nothing changed")
    pos = at.start() if at.re is old else at.end()
    s = s[:pos] + f"    include {snip};   # headers, rate limits, read only (web/security.conf)\n" + s[pos:]
s = old.sub("", s)
if s != open(path).read():
    open(path, "w").write(s)
    print("  site now uses the security settings")
else:
    print("  site already uses the security settings")
PY

  sudo sed -i -E 's/^([[:space:]]*)#[[:space:]]*server_tokens off;/\1server_tokens off;/' "$MAIN"
  if sudo grep -qE '^[[:space:]]*server_tokens off;' "$MAIN"; then echo "  Nginx version hidden on every site"; fi

  echo "== Test and reload =="
  if ! sudo nginx -t 2>"$BAK/test.log"; then
    for f in "$SITE" "$SNIP" "$LIMITS" "$MAIN"; do
      if [ -f "$BAK/$(basename "$f")" ]; then sudo cp -a "$BAK/$(basename "$f")" "$f"; else sudo rm -f "$f"; fi
    done
    echo "  Nginx rejected the new settings, so every file was put back and the site runs as before:"
    sed 's/^/    /' "$BAK/test.log"
    exit 1
  fi
  sudo systemctl reload nginx
  sleep 2                                  # let the old Nginx workers finish
  echo "  config valid, Nginx reloaded"
}

check() {
  local url=https://$DOMAIN hdr h burst
  code() { curl -sS -o /dev/null -w "%{http_code}" "$@"; }
  echo "== Check from outside =="
  hdr=$(curl -sS -D - -o /dev/null "$url/" | tr -d '\r')
  for h in Strict-Transport-Security Content-Security-Policy X-Content-Type-Options X-Frame-Options \
           Referrer-Policy Permissions-Policy Cross-Origin-Opener-Policy Cross-Origin-Resource-Policy; do
    if grep -qi "^$h:" <<<"$hdr"; then echo "  ok       $h"; else echo "  MISSING  $h"; fi
  done
  echo "  Server header says: $(grep -i '^server:' <<<"$hdr" | cut -d' ' -f2-)   (want just nginx)"
  echo "  POST /             -> $(code -X POST "$url/")   (want 405)"
  echo "  GET /.git/config   -> $(code "$url/.git/config")   (want 403)"
  echo "  GET /status.json   -> $(code "$url/status.json")   (want 200)"
  echo "  http:// redirect   -> $(code "http://$DOMAIN/")   (want 301)"
  burst=$(for _ in $(seq 40); do code "$url/status.json"; echo; done | sort | uniq -c | awk '{printf "%s x %s  ", $1, $2}')
  echo "  40 quick requests  -> $burst  (some 429 means the rate limit works)"
}

case $MODE in
  --apply) apply ;;
  --check) check ;;
  all) apply; check ;;
  *) echo "Use: ./harden-web.sh [--apply | --check]"; exit 1 ;;
esac
