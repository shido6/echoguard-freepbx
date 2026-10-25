#!/bin/bash
# Remove the Echo connector from this box.
#
# Order matters: the upstream installer knows about the HEP dialplan include,
# the systemd unit, the helper and the log rotation it created. Ask it to
# clean up first, then remove what this package added (the FreePBX page).
set -euo pipefail

ECHO_BASE="https://echo.echoguard.ca"
CONNECT_URL="${ECHO_BASE}/connector/connect.sh"
MANIFEST_URL="${ECHO_BASE}/connector/manifest.json"
MODULE_DIR="/var/www/html/admin/modules/echoguard"
STATE_DIR="/var/lib/echo-connector"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"

removed_connector=0
if remote="$(mktemp)" && curl -fsS --proto '=https' --tlsv1.2 --max-time 60 "$CONNECT_URL" -o "$remote"; then
  if manifest="$(mktemp)" && curl -fsS --proto '=https' --tlsv1.2 --max-time 30 "$MANIFEST_URL" -o "$manifest"; then
    want="$(python3 - "$manifest" <<'PY'
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("files") or {}).get("connect.sh") or "")
except Exception:
    print("")
PY
)"
    got="$(sha256sum "$remote" | awk '{print $1}')"
    if [[ -n "$want" && "$got" == "$want" ]]; then
      say "running the upstream installer's uninstall"
      bash "$remote" --uninstall && removed_connector=1
    else
      echo "warning: could not verify the upstream installer; skipping its uninstall" >&2
    fi
    rm -f "$manifest"
  fi
  rm -f "$remote"
fi

if [[ "$removed_connector" -eq 0 ]]; then
  echo "warning: the connector may still be installed. If signalling continues, run:" >&2
  echo "         curl -fsSL ${CONNECT_URL} | sudo bash -s -- --uninstall" >&2
fi

say "removing the FreePBX console page"
if command -v fwconsole >/dev/null 2>&1; then
  fwconsole ma delete echoguard >/dev/null 2>&1 || true
fi
rm -rf "$MODULE_DIR"

say "removing connector status files"
# The upstream uninstall removes /opt/echo-connector (and the key with it) and
# the systemd unit; these two directories are what it leaves behind.
rm -rf "$STATE_DIR"

if command -v fwconsole >/dev/null 2>&1; then
  fwconsole ma list >/dev/null 2>&1 || true
  fwconsole reload >/dev/null 2>&1 || true
fi

cat <<EOF

Removed. Two things are deliberately left alone:

  /var/log/echo-connector/   install/audit/agent logs (delete when you no longer
                             want the audit trail)
  /var/backups/echo-connector/  original hep.conf, restored already

Revoke the node in the Echo dashboard so its key cannot be reused:
  ${ECHO_BASE}  ->  Phone systems
EOF
