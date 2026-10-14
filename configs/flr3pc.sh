# needs: eth1
# FLR3PC: Florence site 3 PC
# Packet Tracer: ipconfig 10.4.3.2 255.255.255.0 10.4.3.1
ip link set eth1 up
ip addr add 10.4.3.2/24 dev eth1
ip route replace default via 10.4.3.1 dev eth1
