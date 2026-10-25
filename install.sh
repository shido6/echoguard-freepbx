#!/bin/bash
# Echo connector for FreePBX — installer v0.2
#
# Usage:
#   sudo ./install.sh 'EC-<node_id>.<key>'      # connect this box
#   sudo ./install.sh --uninstall               # remove it again
#   ./install.sh --check-only                   # verify the upstream installer, change nothing
#   sudo ./install.sh 'EC-...' --dry-run        # show every change, write nothing
#   sudo ./install.sh 'EC-...' --adopt-existing # box already sends signals somewhere else
#
# The key comes from your Echo page: press "+ Connect a phone system", name it,
# press "Generate the one-line setup", and take the quoted part. It looks like
#   EC-7f3a9c21.<64 hex chars>
# and it is shown once, valid for 24 hours. This script never asks for a new one.
#
# What this script is: a FreePBX-shaped wrapper around the official Echo
# connector. It downloads https://echo.echoguard.ca/connector/connect.sh,
# refuses to run it unless its SHA-256 matches the published manifest,
# then hands your key to it. The connector itself is what configures
# Asterisk's HEP copy, runs the local helper, and heartbeats to Echo.
#
# What this script adds on top: the FreePBX admin page (module.xml +
# page.echoguard.php) so the node status is visible inside FreePBX, and a
# world-readable node.json so that page does not need the node key.
set -euo pipefail

ECHO_BASE="https://echo.echoguard.ca"
CONNECT_URL="${ECHO_BASE}/connector/connect.sh"
MANIFEST_URL="${ECHO_BASE}/connector/manifest.json"

MODULE_DIR="/var/www/html/admin/modules/echoguard"
STATE_DIR="/var/lib/echo-connector"
NODE_INFO="${STATE_DIR}/node.json"

TOKEN=""
DRY_RUN=0
NO_MODULE=0
UNINSTALL=0
CHECK_ONLY=0
ADOPT=0

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    EC-*)            TOKEN="$1"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --no-module)     NO_MODULE=1; shift ;;
    --adopt-existing) ADOPT=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    --check-only)    CHECK_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ "$UNINSTALL" -eq 0 && "$CHECK_ONLY" -eq 0 ]]; then
  [[ -n "$TOKEN" ]] || die "no setup key. Pass the EC-... string from the Echo dashboard."
  [[ "$TOKEN" =~ ^EC-[0-9a-fA-F]{8}\.[0-9a-fA-F]{64}$ ]] \
    || die "that does not look like an Echo setup key (expected EC-<8 hex>.<64 hex>)"
fi

as_root() {
  [[ "$(id -u)" -eq 0 ]]
}

detect_platform() {
  if command -v fwconsole >/dev/null 2>&1 || [[ -d /etc/freepbx ]] || [[ -d /var/www/html/admin ]]; then
    echo freepbx
  elif command -v asterisk >/dev/null 2>&1 || [[ -d /etc/asterisk ]]; then
    echo asterisk
  else
    echo unknown
  fi
}

# Signals only flow if Asterisk's HEP capture modules are loaded. Upstream
# writes hep.conf and reloads them, but a reload of a module that was never
# loaded is a no-op — common on FreePBX, where res_hep* is present but idle.
# Loading is idempotent and changes no configuration file, so do it and then
# report the real state instead of assuming it worked.
ensure_capture_modules() {
  command -v asterisk >/dev/null 2>&1 || return 0
  local mod status
  # Loading an already-loaded module is a harmless no-op, so do not try to
  # guess which one is missing from `module show` output — just ask for both
  # and then report what is really running.
  for mod in res_hep.so res_hep_pjsip.so; do
    asterisk -rx "module load ${mod}" >/dev/null 2>&1 || true
  done

  status="$(asterisk -rx 'module show like res_hep' 2>/dev/null || true)"
  if grep -qE 'res_hep(_pjsip)?\.so' <<<"$status"; then
    say "capture modules loaded: $(grep -oE 'res_hep(_pjsip)?\.so' <<<"$status" | sort -u | tr '\n' ' ')"
  else
    echo "warning: res_hep modules are not loaded, so this node will connect but" >&2
    echo "         forward no signals. Load them and check modules.conf for noload=:" >&2
    echo "           asterisk -rx 'module load res_hep.so'" >&2
    echo "           asterisk -rx 'module load res_hep_pjsip.so'" >&2
  fi
}

# ------------------------------------------------------------------ download
# Fetch the official installer and prove it is the one the manifest pins.
# This is the same chain of custody the Echo installer applies to itself;
# doing it here means a poisoned copy never reaches bash.
# Sets DL_DIR and CONNECT_FILE; callers clean up with cleanup_download.
DL_DIR=""
CONNECT_FILE=""

download_verified() {
  local manifest connect want got
  DL_DIR="$(mktemp -d)"
  manifest="${DL_DIR}/manifest.json"
  connect="${DL_DIR}/connect.sh"

  say "fetching ${MANIFEST_URL}"
  curl -fsS --proto '=https' --tlsv1.2 --max-time 30 "$MANIFEST_URL" -o "$manifest" \
    || die "could not fetch the manifest"

  say "fetching ${CONNECT_URL}"
  curl -fsS --proto '=https' --tlsv1.2 --max-time 60 "$CONNECT_URL" -o "$connect" \
    || die "could not fetch the installer"

  want="$(python3 - "$manifest" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print("manifest-unreadable", file=sys.stderr)
    raise SystemExit(1)
print((data.get("files") or {}).get("connect.sh") or "")
PY
)" || die "the manifest is not readable JSON"

  [[ -n "$want" ]] || die "the manifest does not pin connect.sh"

  got="$(sha256sum "$connect" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    die "integrity check failed: connect.sh is ${got}, manifest pins ${want}. Nothing was run."
  fi
  say "integrity ok (sha256 ${got:0:16}...)"
  CONNECT_FILE="$connect"
}

cleanup_download() {
  [[ -n "$DL_DIR" ]] && rm -rf "$DL_DIR"
}

# ------------------------------------------------------------------ checks
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  download_verified
  bash -n "$CONNECT_FILE" || die "the downloaded installer is not valid bash"
  say "check passed. platform=$(detect_platform). Nothing was changed."
  cleanup_download
  exit 0
fi

if ! as_root; then
  # The upstream installer requires root even for its own dry run (it reads
  # protected config to decide what it would change). --check-only is the
  # non-root path.
  die "run as root (sudo) — --check-only works without root"
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
  exec "$(dirname "$0")/uninstall.sh"
fi

PLATFORM="$(detect_platform)"
[[ "$PLATFORM" != "unknown" ]] || die "no FreePBX or Asterisk found on this box"

say "platform detected: ${PLATFORM}"

# Read the helper's own counter so we can tell whether this install produced a
# fresh successful send (as opposed to a send that happened before an upgrade).
state_last_send() {
  python3 - "${STATE_DIR}/state.json" 2>/dev/null <<'PY' || echo 0
import json, sys
try:
    print(int(json.load(open(sys.argv[1])).get("last_send_ok") or 0))
except Exception:
    print(0)
PY
}

SEND_BEFORE="$(state_last_send)"

# ------------------------------------------------------------------ connector
download_verified

if [[ "$DRY_RUN" -eq 1 ]]; then
  say "dry run - the upstream installer will be run in its own dry-run mode"
  bash "$CONNECT_FILE" "$TOKEN" --dry-run || die "upstream dry run failed"
  say "would also install the FreePBX module into ${MODULE_DIR} and ${NODE_INFO}"
  cleanup_download
  exit 0
fi

CONNECT_ARGS=("$TOKEN")
[[ "$ADOPT" -eq 1 ]] && CONNECT_ARGS+=(--adopt-existing)

say "running the Echo connector (this is what configures HEP capture and the service)"
bash "$CONNECT_FILE" "${CONNECT_ARGS[@]}" \
  || die "the Echo connector failed; nothing further was installed"
cleanup_download

if [[ "$PLATFORM" == "freepbx" || "$PLATFORM" == "asterisk" ]]; then
  ensure_capture_modules
fi

# Wait for the helper's first successful send to Echo, so the installer either
# confirms delivery or says plainly that it has not happened yet.
REPORTED="not yet"
for _ in $(seq 1 20); do
  SEND_NOW="$(state_last_send)"
  if [[ "$SEND_NOW" -gt "$SEND_BEFORE" && "$SEND_NOW" -gt 0 ]]; then
    REPORTED="confirmed (Echo accepted a signal at $(date -d @"$SEND_NOW" '+%H:%M:%S' 2>/dev/null || echo "$SEND_NOW"))"
    break
  fi
  sleep 1
done

NODE_ID="${TOKEN#EC-}"
NODE_ID="${NODE_ID%%.*}"

# ------------------------------------------------------------------ status file
# The node id is not a secret; the key stays in root-only agent.env. The
# FreePBX page reads this file as the web user.
install -d -m 755 "$STATE_DIR"
cat > "$NODE_INFO" <<JSON
{"node_id": "${NODE_ID}", "platform": "${PLATFORM}", "endpoint": "${ECHO_BASE}", "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
chmod 644 "$NODE_INFO"

# ------------------------------------------------------------------ module
if [[ "$NO_MODULE" -eq 0 ]]; then
  if [[ -d /var/www/html/admin/modules ]]; then
    say "installing the FreePBX console page"
    install -d -m 755 "$MODULE_DIR"
    SRC="$(dirname "$0")"
    install -m 644 "${SRC}/module.xml" "${MODULE_DIR}/module.xml"
    install -m 644 "${SRC}/page.echoguard.php" "${MODULE_DIR}/page.echoguard.php"
    if id asterisk >/dev/null 2>&1; then
      chown -R asterisk:asterisk "$MODULE_DIR" 2>/dev/null || true
    fi
    if command -v fwconsole >/dev/null 2>&1; then
      fwconsole ma list >/dev/null 2>&1 || true      # refresh the module registry
    fi
    say "module installed: Admin -> Connectivity -> Echo connector"
  else
    echo "note: this does not look like a FreePBX admin tree; skipping the console page"
  fi
else
  say "skipping the FreePBX console page (--no-module)"
fi

# ------------------------------------------------------------------ report
cat <<EOF

Connected.

  node      : ${NODE_ID}
  platform  : ${PLATFORM}
  endpoint  : ${ECHO_BASE}
  service   : systemctl status echo-connector
  first send: ${REPORTED}
  your page : ${ECHO_BASE}

Signals appear in your account as calls happen. If the node goes quiet, check
\`systemctl status echo-connector\` and \`tail /var/log/echo-connector/agent.log\`.

Removing the node on your Echo page rejects the key on the next heartbeat.
EOF
