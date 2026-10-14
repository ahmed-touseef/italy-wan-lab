#!/usr/bin/env bash
# Checks the Italy WAN lab. Run from the repo folder: ./verify.sh
set -uo pipefail
L=clab-italy
ROUTERS="milan turin genoa florence rome naples"
x() { sudo docker exec "$L-$1" "${@:2}"; }
fails=0

echo "== 1. Devices running (expect 54) =="
up=$(sudo docker ps -q --filter label=containerlab=italy | wc -l)
echo "  $up of 54"
[ "$up" -eq 54 ] || fails=$((fails + 1))

echo "== 2. OSPF ring neighbors (2 FULL per router; first boot takes about 40 s) =="
for _ in $(seq 1 45); do
  ok=1
  for r in $ROUTERS; do
    [ "$(x "$r" vtysh -c 'show ip ospf neighbor' | grep -c Full)" -ge 2 ] || ok=0
  done
  [ "$ok" -eq 1 ] && break
  sleep 2
done
for r in $ROUTERS; do
  nb=$(x "$r" vtysh -c 'show ip ospf neighbor' | awk '/Full/ {printf " %s", $1}')
  c=$(echo "$nb" | wc -w)
  printf "  %-9s %s FULL:%s\n" "$r" "$c" "$nb"
  [ "$c" -eq 2 ] || fails=$((fails + 1))
done

echo "== 3. Milan's OSPF routes (expect 24; the table fills a few seconds after FULL) =="
for _ in $(seq 1 15); do
  routes=$(x milan vtysh -c 'show ip route ospf')
  n=$(echo "$routes" | grep -c '^O>')
  [ "$n" -ge 24 ] && break
  sleep 2
done
echo "$routes" | grep -E '^O>|^ +\*'
echo "  total: $n"
[ "$n" -eq 24 ] || fails=$((fails + 1))

echo "== 4. Ping from mil1pc (Milan site 1) to every PC and switch =="
printf "  %-9s %-8s %-8s %-8s %-8s\n" city site1 site2 site3 site4
c=1
for r in $ROUTERS; do
  line=$(printf "  %-9s" "$r")
  for s in 1 2 3 4; do
    pc=FAIL; sw=FAIL
    x mil1pc ping -q -c 2 -i 0.2 -W 1 "10.$c.$s.2" >/dev/null 2>&1 && pc=ok
    x mil1pc ping -q -c 2 -i 0.2 -W 1 "10.$c.$s.7" >/dev/null 2>&1 && sw=ok
    [ "$pc$sw" = okok ] || fails=$((fails + 1))
    line+=$(printf " %-8s" "$pc/$sw")
  done
  echo "$line"
  c=$((c + 1))
done
echo "  (each cell: PC/switch)"

echo "== 5. Traceroute mil1pc to Rome site 1 (short way, via Naples) =="
x mil1pc traceroute -n -q 1 -w 1 10.5.1.2
echo "== 6. Florence is 3 cities away both ways: Milan keeps 2 equal paths (ECMP) =="
x milan vtysh -c 'show ip route 10.4.1.0/24' | grep -E 'Known|metric|\*'

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $fails check(s) failed"; fi
exit "$fails"
