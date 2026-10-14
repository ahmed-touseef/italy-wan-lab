# needs: eth1 eth2
# TRN4SW: Turin site 4 switch (the 2960 in Packet Tracer)
ip link add vlan1 type bridge             # the switch itself: all ports in VLAN 1
ip link set eth1 master vlan1             # uplink to the turin router
ip link set eth2 master vlan1             # port to trn4pc
ip link set eth1 up
ip link set eth2 up
ip link set vlan1 up
ip addr add 10.2.4.7/24 dev vlan1       # interface vlan 1 + ip address
ip route replace default via 10.2.4.1   # ip default-gateway
