#!/usr/bin/env bash
set -euo pipefail

echo "==> Enabling linger..."

loginctl enable-linger httpd
loginctl enable-linger experiments

echo "==> Reloading user systemd..."

su - httpd -c "systemctl --user daemon-reload"
su - experiments -c "systemctl --user daemon-reload"

echo "==> Enabling services..."

su - httpd -c "systemctl --user enable webdav.service"
su - experiments -c "systemctl --user enable postgres.service"

echo "==> Starting services..."

su - httpd -c "systemctl --user start webdav.service"
su - experiments -c "systemctl --user start postgres.service"

echo "==> Enabling podman auto-update timers..."

su - httpd -c "systemctl --user enable podman-auto-update.timer"
su - experiments -c "systemctl --user enable podman-auto-update.timer"

echo "==> Enabling bootc auto-update timer..."

systemctl enable bootc-fetch-apply-updates.timer

echo "✅ User services + updates initialized"
