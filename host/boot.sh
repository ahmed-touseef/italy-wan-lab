#!/bin/sh
# Waits until the cables listed on the "# needs:" line of /config.sh exist,
# runs /config.sh once (log in /tmp/config.log), then idles until stopped.
if [ -f /config.sh ]; then
  need=$(sed -n 's/^# needs: //p' /config.sh)
  i=0
  while [ "$i" -lt 60 ]; do
    missing=0
    for n in $need; do [ -e "/sys/class/net/$n" ] || missing=1; done
    [ "$missing" -eq 0 ] && break
    i=$((i + 1)); sleep 1
  done
  sh -x /config.sh > /tmp/config.log 2>&1
fi
trap 'exit 0' TERM INT
sleep infinity & wait
