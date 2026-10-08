#!/bin/sh
# Stub k3s install.sh: records its environment, writes the unit and starts k3s.
printf 'install.sh SKIP_DOWNLOAD=%s EXEC=%s\n' "${INSTALL_K3S_SKIP_DOWNLOAD}" "${INSTALL_K3S_EXEC}" >> "${STUB_CALLS:?}"
mkdir -p "${INSTALL_K3S_SYSTEMD_DIR}"
echo "[Service]" > "${INSTALL_K3S_SYSTEMD_DIR}/k3s.service"
systemctl restart k3s
