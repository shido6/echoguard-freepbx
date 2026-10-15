#!/bin/bash
# EchoGuard connector installer — v0.1
# Usage: sudo ./install.sh --endpoint https://app.echoguard.ca --node 3 --key <one-time-key>
set -euo pipefail

ENDPOINT=""
NODE_ID=""
KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --node)     NODE_ID="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ENDPOINT" || -z "$NODE_ID" || -z "$KEY" ]]; then
  echo "usage: $0 --endpoint URL --node ID --key KEY" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

echo "==> installing files"
install -d /etc/echoguard /var/lib/echoguard /usr/local/lib/echoguard
install -m 755 bin/echoguard-agent.py /usr/local/bin/echoguard-agent
install -m 644 bin/echoguard_ops.php /usr/local/lib/echoguard/echoguard_ops.php
install -m 644 echoguard-agent.service /etc/systemd/system/echoguard-agent.service

umask 077
cat > /etc/echoguard/agent.conf <<EOF
[echoguard]
endpoint = ${ENDPOINT}
node_id = ${NODE_ID}
key = ${KEY}
EOF
chmod 600 /etc/echoguard/agent.conf

echo "==> enabling service"
systemctl daemon-reload
systemctl enable --now echoguard-agent.service

echo "==> self-test"
/usr/local/bin/echoguard-agent self-test || {
  echo "self-test reported problems — check: journalctl -u echoguard-agent -n 50" >&2
  exit 1
}

echo "done. The agent checks in within ~15s; status appears in your EchoGuard console."
