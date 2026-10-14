# needs: eth1
# TRN4PC: Turin site 4 PC
# Packet Tracer: ipconfig 10.2.4.2 255.255.255.0 10.2.4.1
ip link set eth1 up
ip addr add 10.2.4.2/24 dev eth1
ip route replace default via 10.2.4.1 dev eth1
