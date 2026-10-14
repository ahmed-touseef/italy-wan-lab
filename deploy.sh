#!/usr/bin/env bash
# Builds and starts the Italy WAN lab. Run from the repo folder: ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

avail=$(free -m | awk '/^Mem:/ {print $7}')
echo "Available RAM: ${avail} MB (the lab needs about 800 MB)"
if [ "$avail" -lt 1200 ]; then
  echo "Less than 1.2 GB free: stopping to protect the websites on this server."
  exit 1
fi

if ip -4 route | grep -q '^172\.30\.40\.' && ! sudo docker network inspect italy-mgmt >/dev/null 2>&1; then
  echo "172.30.40.0/24 is already used by something else on this server: stopping."
  exit 1
fi

python3 gen.py
echo "Building the switch and PC image..."
sudo docker build -q -t italy-host:1 host/
sudo containerlab deploy -t italy.clab.yml --reconfigure
if [ -s secrets/peers ]; then ./remote-access.sh up; fi   # WireGuard into Milan, once set up
