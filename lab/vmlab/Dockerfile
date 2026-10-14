# Disposable VM lab: real KVM virtual machines (QEMU) running INSIDE this container, so nothing is installed on the
# host. Needs --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN. The lab bridge, taps and NAT live in this
# container's own network namespace only.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      qemu-system-x86 qemu-utils cloud-image-utils genisoimage openssh-client iproute2 nftables \
      ca-certificates curl socat procps iputils-ping python3-minimal \
 && rm -rf /var/lib/apt/lists/*
COPY vmlab.sh /usr/local/bin/vmlab
ENTRYPOINT ["/usr/local/bin/vmlab"]
CMD ["serve"]
