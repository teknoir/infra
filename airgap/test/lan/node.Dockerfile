# Test "node" for the teknoir-airgap LAN tests: Debian 13 with sshd, sudo
# (password required, like a fresh install) and a fake k3s.
FROM docker.io/library/debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server sudo iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash -G sudo teknoir \
 && echo 'teknoir:teknoir-test-pw' | chpasswd \
 && mkdir -p /run/sshd /etc/fake-k3s /etc/rancher/k3s /home/teknoir/.ssh \
 && chown teknoir:teknoir /home/teknoir/.ssh && chmod 700 /home/teknoir/.ssh
COPY fake/k3s /usr/local/bin/k3s
CMD ["sh", "-c", "ssh-keygen -A >/dev/null && exec /usr/sbin/sshd -D -e"]
