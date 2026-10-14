#!/usr/bin/env bash
# Publishes the live status page at https://wan.touseefahmed.com
# Installs the collector service, the page files, an Nginx site with its security
# settings (harden-web.sh) and a Let's Encrypt certificate. Other sites keep their
# settings; only the Nginx version is hidden server wide. Run: ./publish.sh
set -euo pipefail
cd "$(dirname "$0")"
DOMAIN=wan.touseefahmed.com
WEB=/var/www/italy-wan
SITE=/etc/nginx/sites-available/$DOMAIN

echo "== 1. DNS =="
dns=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')
if [ -z "$dns" ]; then
  echo "  $DOMAIN has no DNS record yet. Add the A record, wait a few minutes, then run ./publish.sh again."
  exit 1
fi
if ! hostname -I | tr ' ' '\n' | grep -qx "$dns"; then
  echo "  $DOMAIN points to $dns, which is not this server. Fix the A record first."
  exit 1
fi
echo "  $DOMAIN -> $dns (this server)"

echo "== 2. Status collector =="
sudo install -d -m 755 /opt/italy-wan "$WEB" /var/lib/italy-wan
sudo install -m 644 gen.py status/collect.py /opt/italy-wan/
sudo install -m 644 status/italy-wan-status.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable -q italy-wan-status.service
sudo systemctl restart italy-wan-status.service
for _ in $(seq 1 30); do [ -s "$WEB/status.json" ] && break; sleep 1; done
if [ ! -s "$WEB/status.json" ]; then
  echo "  The collector did not write status.json. Its log:"
  sudo journalctl -u italy-wan-status -n 20 --no-pager
  exit 1
fi
echo "  running, status.json written"

echo "== 3. Page files =="
sudo install -m 644 web/index.html web/style.css web/app.js "$WEB/"
echo "  copied to $WEB"

echo "== 4. Nginx site and its security settings =="
new_site=0
[ -f "$SITE" ] || { sudo install -m 644 web/nginx.conf "$SITE"; new_site=1; }
sudo ln -sf "$SITE" "/etc/nginx/sites-enabled/$DOMAIN"
if ! ./harden-web.sh --apply; then
  if [ "$new_site" = 1 ]; then sudo rm -f "/etc/nginx/sites-enabled/$DOMAIN" "$SITE"; fi
  exit 1
fi

echo "== 5. HTTPS certificate =="
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --redirect --keep-until-expiring

echo "== 6. Check from outside =="
curl -sS -o /dev/null -w "  https://$DOMAIN/ -> HTTP %{http_code}\n" "https://$DOMAIN/"
curl -sS "https://$DOMAIN/status.json" | python3 -c "import json, sys, time; d = json.load(sys.stdin); print('  status.json:', d['devices']['running'], 'of 54 devices running, written', int(time.time() - d['generated']), 's ago')"
./harden-web.sh --check
echo "Done: open https://$DOMAIN"
