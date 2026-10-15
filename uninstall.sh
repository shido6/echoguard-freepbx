#!/bin/bash
# Remove the EchoGuard connector. Keeps nothing behind.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi
systemctl disable --now echoguard-agent.service 2>/dev/null || true
rm -f /etc/systemd/system/echoguard-agent.service
rm -f /usr/local/bin/echoguard-agent
rm -rf /usr/local/lib/echoguard
rm -rf /etc/echoguard /var/lib/echoguard
systemctl daemon-reload
echo "removed. Revoke the node in the EchoGuard console so the key cannot be reused."
