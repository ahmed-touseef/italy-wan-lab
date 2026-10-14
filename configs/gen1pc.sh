# needs: eth1
# GEN1PC: Genoa site 1 PC
# Packet Tracer: ipconfig 10.3.1.2 255.255.255.0 10.3.1.1
ip link set eth1 up
ip addr add 10.3.1.2/24 dev eth1
ip route replace default via 10.3.1.1 dev eth1
