#!/usr/bin/env python3
"""Collects the live state of the Italy WAN lab into status.json for the web page.

Read only: it runs show commands, pings and traceroutes inside the lab and never
changes anything. systemd runs it every 15 seconds (italy-wan-status.timer).
The network tables come from gen.py, so the page always matches the lab.
"""
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen  # noqa: E402  (CITIES, SITES, RING, ring_link)

OUT = Path(os.environ.get("ITALY_WAN_OUT", "/var/www/italy-wan/status.json"))
STATE = Path(os.environ.get("ITALY_WAN_STATE", "/var/lib/italy-wan/state.json"))
PEERS = Path(os.environ.get("ITALY_WAN_PEERS", "/var/lib/italy-wan/peers.json"))
CONNECTED_S = 180          # a WireGuard peer counts as connected if it shook hands this recently
SILENT_S = 60              # ...and sent something lately: PCs send a keepalive every 25 s
LAST_RX = {}               # name: (bytes received, when that number last grew)
LAB = "clab-italy"
ORIGIN = "mil1pc"            # every ping and traceroute starts at Milan site 1
MAX_EVENTS = 40

LABEL = {name: name.capitalize() for name, _, _ in gen.CITIES}
NUM = {name: n for name, n, _ in gen.CITIES}
CODE = {name: code for name, _, code in gen.CITIES}
RID = {name: f"{n}.{n}.{n}.{n}" for name, n, _ in gen.CITIES}
CITY_BY_RID = {rid: name for name, rid in RID.items()}


def run(node, cmd, timeout=15):
    try:
        r = subprocess.run(["docker", "exec", f"{LAB}-{node}", "sh", "-c", cmd],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else ""
    except (subprocess.SubprocessError, OSError):
        return ""


def running_devices():
    try:
        r = subprocess.run(["docker", "ps", "-q", "--filter", "label=containerlab=italy"],
                           capture_output=True, text=True, timeout=15)
        return len(r.stdout.split())
    except (subprocess.SubprocessError, OSError):
        return 0


def ip_map():
    """Every lab address mapped to the device that owns it."""
    m = {}
    for name, n, code in gen.CITIES:
        for s in gen.SITES:
            m[f"10.{n}.{s}.1"] = name
            m[f"10.{n}.{s}.2"] = f"{code}{s}pc"
            m[f"10.{n}.{s}.7"] = f"{code}{s}sw"
    for a, _, b, _ in gen.RING:
        _, ips = gen.ring_link(a, b)
        for city, ip in ips.items():
            m[ip] = city
    return m


def router_state(name):
    """OSPF neighbors (router ID: state) and ring port states for one router."""
    nbrs = {}
    for line in run(name, "vtysh -c 'show ip ospf neighbor'").splitlines():
        f = line.split()
        if len(f) >= 7 and re.fullmatch(r"\d+\.\d+\.\d+\.\d+", f[0]):
            nbrs[f[0]] = f[2].split("/")[0]
    ports = {}
    for line in run(name, "for i in eth5 eth6; do echo $i $(cat /sys/class/net/$i/operstate 2>/dev/null || echo missing); done").splitlines():
        f = line.split()
        if len(f) == 2:
            ports[f[0]] = f[1]
    room = f"{gen.REMOTE['room']}.0/24"
    try:
        entries = json.loads(run(name, f"vtysh -c 'show ip route {room} json'") or "{}").get(room, [])
    except json.JSONDecodeError:
        entries = []
    remote_route = any(e.get("selected") for e in entries)
    return name, {"neighbors": nbrs, "ports": ports, "remote_route": remote_route}


def milan_routes():
    out = run("milan", "vtysh -c 'show ip route ospf json'")
    try:
        return json.loads(out) if out.strip() else {}
    except json.JSONDecodeError:
        return {}


def pings(extra):
    targets = [f"10.{n}.{s}.{h}" for _, n, _ in gen.CITIES for s in gen.SITES for h in (2, 7)] + extra
    cmd = ("for ip in " + " ".join(targets) + "; do "
           "(ping -q -c 2 -i 0.2 -W 1 $ip >/dev/null 2>&1 && echo $ip ok || echo $ip fail) & "
           "done; wait")
    res = {ip: False for ip in targets}
    for line in run(ORIGIN, cmd, timeout=20).splitlines():
        f = line.split()
        if len(f) == 2 and f[0] in res:
            res[f[0]] = f[1] == "ok"
    return res


def trace(city, n, owners):
    target = f"10.{n}.1.2"
    hops = []
    for line in run(ORIGIN, f"traceroute -n -q 1 -w 1 -m 8 {target}", timeout=20).splitlines():
        m = re.match(r"^\s*(\d+)\s+(\S+)", line)
        if not m:
            continue
        ip = None if m.group(2) == "*" else m.group(2)
        hops.append({"ip": ip, "node": owners.get(ip)})
    complete = bool(hops) and hops[-1]["ip"] == target
    return city, {"target": target, "hops": hops, "complete": complete}


def wg_dump():
    """`wg show wg0 dump` inside the Milan router, or None if there is no tunnel."""
    try:
        pid = subprocess.run(["docker", "inspect", "-f", "{{.State.Pid}}", f"{LAB}-{gen.REMOTE['router']}"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        if not pid or pid == "0":
            return None
        r = subprocess.run(["nsenter", "-t", pid, "-n", "wg", "show", gen.REMOTE["port"], "dump"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout if r.returncode == 0 else None
    except (subprocess.SubprocessError, OSError):
        return None


def known_peers():
    try:
        return json.loads(PEERS.read_text())
    except (OSError, json.JSONDecodeError):
        return []


def remote_access(peers):
    """Remote PCs on Milan's wg0. Keys and the PCs' home addresses are never read into the page."""
    info = {"enabled": False, "gateway": f"{gen.REMOTE['room']}.1", "router": gen.REMOTE["router"],
            "port": gen.REMOTE["listen"], "peers": []}
    dump = wg_dump()
    if dump is None:
        return info
    info["enabled"] = True
    by_key = {p["public_key"]: p for p in peers}
    for line in dump.splitlines()[1:]:            # line 0 is the interface itself: skipped
        f = line.split("\t")
        if len(f) < 8:
            continue
        p = by_key.get(f[0], {"name": "unknown", "address": f[3].split("/")[0]})
        hs = int(f[4]) if f[4].isdigit() and int(f[4]) > 0 else None
        info["peers"].append({"name": p["name"], "address": p["address"], "handshake": hs,
                              "rx": int(f[5]) if f[5].isdigit() else 0,
                              "tx": int(f[6]) if f[6].isdigit() else 0})
    return info


def collect():
    owners = ip_map()
    devices = running_devices()
    peers = known_peers()
    for p in peers:
        owners[p["address"]] = p["name"]
    with ThreadPoolExecutor(max_workers=12) as pool:
        routers_f = [pool.submit(router_state, name) for name, _, _ in gen.CITIES]
        routes_f = pool.submit(milan_routes)
        pings_f = pool.submit(pings, [p["address"] for p in peers])
        remote_f = pool.submit(remote_access, peers)
        traces_f = [pool.submit(trace, name, n, owners)
                    for name, n, _ in gen.CITIES if name != "milan"]
        routers = dict(f.result() for f in routers_f)
        routes = routes_f.result()
        reach = pings_f.result()
        paths = dict(f.result() for f in traces_f)
        remote = remote_f.result()

    links = []
    for a, pa, b, pb in gen.RING:
        room, ips = gen.ring_link(a, b)
        cable = ("up" if routers[a]["ports"].get(pa) == "up" and routers[b]["ports"].get(pb) == "up"
                 else "down")
        full = (routers[a]["neighbors"].get(RID[b]) == "Full"
                and routers[b]["neighbors"].get(RID[a]) == "Full")
        links.append({"a": a, "b": b, "subnet": f"{room}.0/30",
                      "a_port": pa, "b_port": pb, "a_ip": ips[a], "b_ip": ips[b],
                      "cable": cable, "ospf": "full" if full else "down"})

    cities = []
    for name, n, code in gen.CITIES:
        sites = [{"site": s, "subnet": f"10.{n}.{s}.0/24",
                  "pc": {"ip": f"10.{n}.{s}.2", "ok": reach.get(f"10.{n}.{s}.2", False)},
                  "switch": {"ip": f"10.{n}.{s}.7", "ok": reach.get(f"10.{n}.{s}.7", False)}}
                 for s in gen.SITES]
        full = sum(1 for st in routers[name]["neighbors"].values() if st == "Full")
        cities.append({"name": name, "label": LABEL[name], "num": n, "code": code,
                       "rid": RID[name], "ospf_full": full, "sites": sites})

    route_rows = []
    for name, n, _ in gen.CITIES:
        if name == "milan":
            continue
        cost, via, learned = None, set(), 0
        for s in gen.SITES:
            for r in routes.get(f"10.{n}.{s}.0/24", []):
                if not r.get("selected"):
                    continue
                learned += 1
                if s == 1:
                    cost = r.get("metric")
                    via = {owners.get(h.get("ip")) for h in r.get("nexthops", [])
                           if h.get("ip") and h.get("active", True)}
        route_rows.append({"city": name, "cost": cost,
                           "via": sorted(v for v in via if v), "sites": learned})

    now = time.time()
    for p in remote["peers"]:
        # WireGuard never says "disconnected": a PC that goes away just falls silent.
        recent_hs = bool(p["handshake"]) and now - p["handshake"] < CONNECTED_S
        seen = LAST_RX.get(p["name"])
        if seen is None:
            LAST_RX[p["name"]] = (p["rx"], now if recent_hs else (p["handshake"] or 0))
        elif p["rx"] != seen[0]:
            LAST_RX[p["name"]] = (p["rx"], now)
        p["last_seen"] = LAST_RX[p["name"]][1] or None
        p["connected"] = recent_hs and now - LAST_RX[p["name"]][1] < SILENT_S
        p["ping"] = reach.get(p["address"], False)
    remote["known_by"] = [name for name, _, _ in gen.CITIES if routers[name]["remote_route"]]

    return {"generated": now, "interval": 15, "remote": remote,
            "devices": {"running": devices, "expected": 54},
            "cities": cities, "links": links, "routes": route_rows, "paths": paths}


def link_text(link):
    return f"{LABEL[link['a']]} to {LABEL[link['b']]} cable"


def update_events(status):
    """Compares with the previous run and records what changed."""
    try:
        prev = json.loads(STATE.read_text())
    except (OSError, json.JSONDecodeError):
        prev = None
    events = prev.get("events", []) if prev else []
    now = status["generated"]

    def add(text):
        events.append({"t": now, "text": text})

    cur = {
        "lab": status["devices"]["running"] > 0,
        "links": {f"{l['a']}-{l['b']}": (l["cable"], l["ospf"]) for l in status["links"]},
        "via": {r["city"]: [r["via"], r["cost"]] for r in status["routes"]},
        "sites": {f"{c['name']}-{s['site']}": s["pc"]["ok"] for c in status["cities"] for s in c["sites"]},
        "peers": {p["name"]: p["connected"] for p in status["remote"]["peers"]},
    }
    if prev is None:
        add("Status collector started")
    elif prev["lab"] != cur["lab"]:
        add("Lab started" if cur["lab"] else "Lab stopped")
    elif cur["lab"]:
        for l in status["links"]:
            key = f"{l['a']}-{l['b']}"
            old = tuple(prev["links"].get(key, ("up", "full")))
            new = (l["cable"], l["ospf"])
            if old == new:
                continue
            if new == ("up", "full"):
                add(f"{link_text(l)} is back up, OSPF FULL again")
            elif new[0] == "down":
                add(f"{link_text(l)} is down")
            else:
                add(f"{link_text(l)} is up but OSPF is not FULL")
        for r in status["routes"]:
            old_via, old_cost = prev["via"].get(r["city"], [[], None])
            if (old_via, old_cost) != (r["via"], r["cost"]) and r["via"]:
                now_via = " and ".join(LABEL[v] for v in r["via"])
                if old_via:
                    was = " and ".join(LABEL[v] for v in old_via)
                    add(f"Milan now reaches {LABEL[r['city']]} via {now_via} (cost {r['cost']}), "
                        f"was via {was} (cost {old_cost})")
                else:
                    add(f"Milan learned a route to {LABEL[r['city']]} via {now_via} (cost {r['cost']})")
        lost = [k for k, ok in cur["sites"].items() if prev["sites"].get(k, True) and not ok]
        back = [k for k, ok in cur["sites"].items() if not prev["sites"].get(k, True) and ok]

        def site_names(keys):
            return ", ".join(f"{LABEL[k.split('-')[0]]} {k.split('-')[1]}" for k in keys)
        if lost:
            add(f"Unreachable from Milan: {site_names(lost)}" if len(lost) <= 6
                else f"{len(lost)} sites became unreachable from Milan")
        if back:
            add(f"Reachable again: {site_names(back)}" if len(back) <= 6
                else f"{len(back)} sites reachable again")
        for name, connected in cur["peers"].items():
            was = prev.get("peers", {}).get(name)
            if connected and not was:
                add(f"{name} connected over WireGuard to the Milan router")
            elif was and not connected:
                add(f"{name} disconnected (nothing heard over WireGuard for {SILENT_S} seconds)")

    events = events[-MAX_EVENTS:]
    cur["events"] = events
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(cur))
    status["events"] = sorted(events, key=lambda e: -e["t"])  # newest first, same moment in order


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, separators=(",", ":")))
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def once():
    status = collect()
    update_events(status)
    write_atomic(OUT, status)


def main():
    """Runs once, or forever with --loop SECONDS (how the systemd service runs it)."""
    if len(sys.argv) == 3 and sys.argv[1] == "--loop":
        every = float(sys.argv[2])
        while True:
            start = time.time()
            try:
                once()
            except Exception as e:  # keep the page alive; the error goes to the journal
                print(f"collector error: {e!r}", file=sys.stderr, flush=True)
            time.sleep(max(1.0, every - (time.time() - start)))
    else:
        once()


if __name__ == "__main__":
    main()
