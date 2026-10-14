# needs: eth1
# MIL2PC: Milan site 2 PC
# Packet Tracer: ipconfig 10.1.2.2 255.255.255.0 10.1.2.1
ip link set eth1 up
ip addr add 10.1.2.2/24 dev eth1
ip route replace default via 10.1.2.1 dev eth1
