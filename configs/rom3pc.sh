# needs: eth1
# ROM3PC: Rome site 3 PC
# Packet Tracer: ipconfig 10.5.3.2 255.255.255.0 10.5.3.1
ip link set eth1 up
ip addr add 10.5.3.2/24 dev eth1
ip route replace default via 10.5.3.1 dev eth1
