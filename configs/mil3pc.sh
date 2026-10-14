# needs: eth1
# MIL3PC: Milan site 3 PC
# Packet Tracer: ipconfig 10.1.3.2 255.255.255.0 10.1.3.1
ip link set eth1 up
ip addr add 10.1.3.2/24 dev eth1
ip route replace default via 10.1.3.1 dev eth1
