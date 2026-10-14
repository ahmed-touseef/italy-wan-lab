# needs: eth1
# ROM1PC: Rome site 1 PC
# Packet Tracer: ipconfig 10.5.1.2 255.255.255.0 10.5.1.1
ip link set eth1 up
ip addr add 10.5.1.2/24 dev eth1
ip route replace default via 10.5.1.1 dev eth1
