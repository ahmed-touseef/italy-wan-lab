# Small Linux used for every switch and PC in the lab
FROM alpine:3.22
RUN apk add --no-cache iproute2 iputils tcpdump
COPY boot.sh /usr/local/bin/boot
RUN chmod +x /usr/local/bin/boot
CMD ["/usr/local/bin/boot"]
