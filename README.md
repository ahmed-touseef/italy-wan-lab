# Italy WAN lab

A six city company network running OSPF. I first built it by hand in Cisco Packet Tracer, then rebuilt it as code with containerlab and FRRouting on a cloud server, keeping the same addresses, ports and OSPF design.

```
   Milan (1) ──── Turin (2) ──── Genoa (3)
      │                              │
   Naples (6) ──── Rome (5) ──── Florence (4)
```

Every city has one router and four sites. Every site has one switch and one PC. That is 54 devices and 54 cables, built with one command.

## Addressing

The address tells you where a device is: **10.CITY.SITE.x**. For example, 10.5.3.2 is Rome, site 3, the PC.

| Device | Address |
|---|---|
| Router (the site's gateway) | .1 |
| PC | .2 |
| Switch (management, VLAN 1) | .7 |

Ring links are small /30 rooms named after the two cities they join: **10.0.XY.0/30**, with the lower city number on .1. Milan to Turin is 10.0.12.0/30, Naples to Milan is 10.0.16.0/30.

| City | Number | Sites | OSPF router ID |
|---|---|---|---|
| Milan | 1 | 10.1.1.0/24 to 10.1.4.0/24 | 1.1.1.1 |
| Turin | 2 | 10.2.1.0/24 to 10.2.4.0/24 | 2.2.2.2 |
| Genoa | 3 | 10.3.1.0/24 to 10.3.4.0/24 | 3.3.3.3 |
| Florence | 4 | 10.4.1.0/24 to 10.4.4.0/24 | 4.4.4.4 |
| Rome | 5 | 10.5.1.0/24 to 10.5.4.0/24 | 5.5.5.5 |
| Naples | 6 | 10.6.1.0/24 to 10.6.4.0/24 | 6.6.6.6 |

## From Packet Tracer to containerlab

| Packet Tracer | Here |
|---|---|
| Router PT | FRRouting container, Cisco style CLI (`vtysh`) |
| 2960 switch | Small Linux container with a bridge called `vlan1`, holding the switch's own .7 address |
| PC | Small Linux container with one network card |
| Fibre cable | Virtual cable (veth pair) |
| Router port Fa0/0, Fa1/0, Fa7/0, Fa6/0 (sites 1 to 4) | eth1, eth2, eth3, eth4 |
| Router port Fa4/0, Fa5/0 (ring) | eth5, eth6 |
| Simulation mode | Live capture with `tcpdump` or Wireshark |

Each port's description in the router config says which Packet Tracer port it replaces.

The interfaces are set to 100 Mbit/s like FastEthernet, so every OSPF cost is 1 and the route table matches Packet Tracer number for number.

## Files

| File | What it is |
|---|---|
| `gen.py` | The whole network in a few tables. Generates everything below |
| `italy.clab.yml` | Topology: devices and cables |
| `configs/<city>.conf` | Router configs |
| `configs/<device>.sh` | Switch and PC setup (the same steps as configuring them by hand) |
| `host/` | The small image used for switches and PCs |
| `deploy.sh` | Builds and starts the lab |
| `verify.sh` | Checks devices, OSPF, routes, pings and paths |

## Run it

```bash
./deploy.sh     # build and start (about 800 MB of RAM)
./verify.sh     # check everything
sudo containerlab destroy -t italy.clab.yml   # remove the lab
```

Open a device, like clicking it in Packet Tracer:

```bash
sudo docker exec -it clab-italy-milan vtysh    # router CLI: show ip route, show ip ospf neighbor
sudo docker exec -it clab-italy-rom1pc sh      # Rome site 1 PC: ping, traceroute
```

The config files are the saved configuration. A change made inside a running router is lost on redeploy, so permanent changes go into `gen.py`, followed by `./deploy.sh`.

## Things to try

**Failover.** Cut the Milan to Naples cable and watch Milan reroute to Rome the long way round through Turin:

```bash
sudo docker exec clab-italy-milan ip link set eth6 down
sudo docker exec clab-italy-mil1pc traceroute -n 10.5.1.2
sudo docker exec clab-italy-milan ip link set eth6 up
```

**Equal paths.** Florence is three cities away in both directions, so Milan keeps both paths and shares traffic between them (ECMP):

```bash
sudo docker exec clab-italy-milan vtysh -c "show ip route 10.4.1.0/24"
```

**Watch packets.** The live version of Packet Tracer's simulation mode:

```bash
sudo docker exec clab-italy-turin tcpdump -ni eth5 icmp or arp
```

## Roadmap

* Step 2: remote access with WireGuard. A laptop joins as 10.9.0.0/24 behind Milan, and OSPF announces it to every city.
