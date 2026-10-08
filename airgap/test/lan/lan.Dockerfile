# Test "LAN host" for the teknoir-airgap LAN tests: bash 3.2 (the macOS
# /bin/bash) with the OpenSSH client, busybox tools and expect (for tty tests).
FROM docker.io/library/bash:3.2
RUN apk add --no-cache openssh-client openssh-keygen expect ca-certificates
