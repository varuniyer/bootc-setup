#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Runtime container/systemd setup
# ----------------------------
ujust set-container-userns on

su - httpd -c "systemctl --user daemon-reload"
su - experiments -c "systemctl --user daemon-reload"

su - httpd -c "systemctl --user enable webdav.service"
su - experiments -c "systemctl --user enable postgres.service"

su - httpd -c "systemctl --user start webdav.service"
su - experiments -c "systemctl --user start postgres.service"

su - httpd -c "systemctl --user enable podman-auto-update.timer"
su - experiments -c "systemctl --user enable podman-auto-update.timer"


# ----------------------------
# Post-install Secureblue setup
# ----------------------------
ujust toggle-mac-randomization
ujust toggle-bash-environment-lockdown
ujust setup-usbguard
ujust enroll-secureblue-secure-boot-key
ujust set-kargs-hardening
ujust bios
ujust setup-luks-tpm-unlock

ujust audit-secureblue | tee /var/log/secureblue-audit.log
chown root:admin /var/log/secureblue-audit.log
chmod 0640 /var/log/secureblue-audit.log
