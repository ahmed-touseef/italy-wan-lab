#!/usr/bin/env bash
# Remote access into the Italy WAN lab over WireGuard.
#
# The tunnel ends on the Milan router as wg0 (10.9.0.1/24), and Milan announces
# 10.9.0.0/24 in OSPF, so every city can reach remote PCs. wg0 is created in the
# server's own network namespace, so its UDP socket listens on the server's public
# address, and is then moved into the Milan router: encrypted packets use the
# server's internet connection, decrypted packets appear inside Milan.
#
#   ./remote-access.sh add NAME PUBLIC_KEY   allow a PC and print the lines for its tunnel
#   ./remote-access.sh up                    rebuild wg0 (deploy.sh runs this after a deploy)
#   ./remote-access.sh show                  peers, handshakes and traffic
#
# Private keys never leave their machine: the server key stays in secrets/ (ignored
# by Git) and every PC keeps its own. Only public keys are exchanged.
set -euo pipefail
cd "$(dirname "$0")"
PORT=51821
ENDPOINT=wan.touseefahmed.com
ROOM=10.9.0
NODE=clab-italy-milan
KEY=secrets/milan-wg.key
PEERS=secrets/peers                    # one line per PC: name address public_key
STATE=/var/lib/italy-wan/peers.json    # names and addresses for the status page

tools() {
  if ! command -v wg >/dev/null; then
    echo "Installing wireguard-tools..."
    sudo apt-get install -y -q wireguard-tools >/dev/null
  fi
  sudo modprobe wireguard
}

milan_pid() {
  local pid
  pid=$(sudo docker inspect -f '{{.State.Pid}}' "$NODE" 2>/dev/null || true)
  if [ -z "$pid" ] || [ "$pid" = 0 ]; then
    echo "The Milan router is not running: start the lab with ./deploy.sh" >&2
    exit 1
  fi
  echo "$pid"
}

in_milan() { sudo nsenter -t "$PID" -n "$@"; }

secrets_dir() { mkdir -p secrets && chmod 700 secrets && touch "$PEERS"; }

up() {
  local name addr pub
  tools
  PID=$(milan_pid)
  secrets_dir
  [ -s "$KEY" ] || (umask 077 && wg genkey > "$KEY")

  in_milan ip link del wg0 2>/dev/null || true
  sudo ip link del italy-wg0 2>/dev/null || true
  if sudo ss -Hlun "sport = :$PORT" | grep -q .; then
    echo "UDP port $PORT is already used by something else on this server: stopping."
    exit 1
  fi

  sudo ip link add italy-wg0 type wireguard     # born on the server: listens on its public address
  sudo ip link set italy-wg0 netns "$PID"       # handed to the Milan router
  in_milan ip link set italy-wg0 name wg0
  in_milan wg set wg0 private-key "$KEY" listen-port "$PORT"
  while read -r name addr pub; do
    if [ -n "${pub:-}" ]; then in_milan wg set wg0 peer "$pub" allowed-ips "$addr/32"; fi
  done < "$PEERS"
  in_milan ip link set wg0 up

  # Milan's side, in its own CLI: the address, and OSPF announcing the room (no OSPF towards PCs)
  sudo docker exec "$NODE" vtysh -c 'configure terminal' -c 'interface wg0' \
    -c 'description WireGuard remote access (created by remote-access.sh)' \
    -c "ip address $ROOM.1/24" -c 'ip ospf passive' -c 'exit' \
    -c 'router ospf' -c "network $ROOM.0/24 area 0" >/dev/null

  if command -v ufw >/dev/null && sudo ufw status | grep -q '^Status: active'; then
    sudo ufw status | grep -q "^$PORT/udp" || sudo ufw allow "$PORT/udp" comment 'Italy WAN lab WireGuard' >/dev/null
  fi

  sudo install -d -m 755 "$(dirname "$STATE")"
  python3 - "$PEERS" <<'PY' | sudo tee "$STATE" >/dev/null
import json, sys
rows = [line.split() for line in open(sys.argv[1]) if len(line.split()) == 3]
print(json.dumps([{"name": n, "address": a, "public_key": k} for n, a, k in rows]))
PY
  echo "wg0 is up on Milan: $ROOM.1/24, UDP port $PORT, $(grep -c . "$PEERS" || true) PC(s) allowed"
}

add() {
  local name=${1:-} pub=${2:-} addr i
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
    echo "Give the PC a short lowercase name, like: ./remote-access.sh add touseef-pc PUBLIC_KEY"
    exit 1
  fi
  if ! [[ "$pub" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
    echo "That is not a WireGuard public key (44 characters ending in =). Copy it from the WireGuard app."
    exit 1
  fi
  secrets_dir
  addr=$(awk -v n="$name" '$1 == n {print $2}' "$PEERS")
  if [ -z "$addr" ]; then
    i=2
    while awk -v a="$ROOM.$i" '$2 == a {f = 1} END {exit !f}' "$PEERS"; do i=$((i + 1)); done
    addr=$ROOM.$i
  fi
  { awk -v n="$name" '$1 != n' "$PEERS"; echo "$name $addr $pub"; } > "$PEERS.new"
  mv "$PEERS.new" "$PEERS"
  up
  echo
  echo "Paste these lines into the WireGuard tunnel on $name, below its PrivateKey line:"
  echo
  cat <<EOF
Address = $addr/32

[Peer]
PublicKey = $(wg pubkey < "$KEY")
Endpoint = $ENDPOINT:$PORT
AllowedIPs = 10.0.0.0/13, $ROOM.0/24
PersistentKeepalive = 25
EOF
}

show() {
  PID=$(milan_pid)
  in_milan wg show wg0
}

case "${1:-}" in
  add) add "${2:-}" "${3:-}" ;;
  up) up ;;
  show) show ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
