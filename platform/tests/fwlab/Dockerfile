# Firewall / host-config lab: a privileged Ubuntu 24.04 container with the real tools (nftables, OpenSSH, WireGuard
# tools, Docker Engine from Docker's apt repo). Used by tests/validate.sh (syntax) and tests/firewall-lab.sh (behaviour).
# Everything happens inside the container's own network namespace — the host's firewall is never touched.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      ca-certificates curl gnupg nftables iproute2 iptables netcat-openbsd openssh-server wireguard-tools jq \
      python3-minimal procps \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update -q && apt-get install -y -q --no-install-recommends docker-ce docker-ce-cli containerd.io \
 && rm -rf /var/lib/apt/lists/*
