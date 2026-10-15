#!/usr/bin/env python3
"""EchoGuard connector agent — outbound-only, stdlib only.

Polls the EchoGuard endpoint for allowlisted commands, runs them via
echoguard_ops.php, and posts results back. Opens no inbound ports.
"""

import argparse
import configparser
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONF = "/etc/echoguard/agent.conf"
STATE = "/var/lib/echoguard/agent-state.json"
LAST_STATUS = "/var/lib/echoguard/last-status.json"
OPS_PHP = "/usr/local/lib/echoguard/echoguard_ops.php"
VERSION = "0.1.0"
POLL_SECONDS = 25


def load_conf(path=CONF):
    cp = configparser.ConfigParser()
    read = cp.read(path)
    if not read:
        raise SystemExit(f"missing config {path} — run install.sh first")
    sect = cp["echoguard"]
    return {
        "endpoint": sect["endpoint"].rstrip("/"),
        "node_id": sect["node_id"],
        "key": sect["key"],
    }


def load_state():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE)


def write_status(payload):
    try:
        os.makedirs(os.path.dirname(LAST_STATUS), exist_ok=True)
        with open(LAST_STATUS, "w") as fh:
            json.dump(payload, fh)
    except OSError:
        pass


def post(path, body, conf, timeout=40):
    req = urllib.request.Request(
        conf["endpoint"] + path,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Echoguard-Node": f"{conf['node_id']}:{conf['key']}",
            "User-Agent": f"echoguard-agent/{VERSION}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode() or "{}")


def detect_freepbx_version():
    for candidate in ("/etc/freepbx_version",):
        try:
            with open(candidate) as fh:
                for line in fh:
                    if "=" in line:
                        return line.split("=", 1)[1].strip()[:40]
        except OSError:
            pass
    try:
        out = subprocess.check_output(["fwconsole", "--version"], timeout=10, text=True)
        return out.strip().splitlines()[0][:40]
    except Exception:
        return "unknown"


def run_op(op, args):
    argv = ["php", OPS_PHP, op, json.dumps(args)]
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    try:
        result = json.loads(proc.stdout or "{}")
    except ValueError:
        result = {"raw": proc.stdout[-4000:]}
    if proc.stderr:
        result["stderr"] = proc.stderr[-2000:]
    return proc.returncode, result


def claim(conf):
    body = post("/api/fpbx/agent/claim", {
        "agent_version": VERSION,
        "freepbx_version": detect_freepbx_version(),
    }, conf, timeout=20)
    write_status({"ok": True, "node_id": conf["node_id"], "checked_in": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    return body


def poll_once(conf, state):
    body = post("/api/fpbx/agent/poll", {}, conf, timeout=POLL_SECONDS + 20)
    for cmd in body.get("commands", []):
        cmd_id = cmd.get("id")
        op = cmd.get("op")
        args = cmd.get("args") or {}
        try:
            code, result = run_op(op, args)
            ok = code == 0
        except subprocess.TimeoutExpired:
            code, result, ok = -1, {"error": "op timed out after 120s"}, False
        except Exception as exc:  # noqa: BLE001 — report, never crash the agent
            code, result, ok = -1, {"error": str(exc)}, False
        seen = state.setdefault("seen", {})
        seen[str(cmd_id)] = True
        if len(seen) > 200:
            for old in list(seen)[:100]:
                seen.pop(old, None)
        save_state(state)
        try:
            post("/api/fpbx/agent/results", {
                "command_id": cmd_id,
                "ok": ok,
                "exit_code": code,
                "result": result,
            }, conf, timeout=20)
        except Exception as exc:  # noqa: BLE001
            print(f"result post failed for {cmd_id}: {exc}", file=sys.stderr)
    return body


def cmd_run(args):
    conf = load_conf()
    state = load_state()
    interval = args.interval
    while True:
        try:
            claim(conf)
            break
        except (urllib.error.URLError, OSError) as exc:
            print(f"claim failed ({exc}); retrying in 30s", file=sys.stderr)
            time.sleep(30)
    while True:
        try:
            poll_once(conf, state)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                write_status({"ok": False, "error": "revoked or bad key"})
                raise SystemExit("node key rejected — re-run install.sh with a fresh setup command")
            write_status({"ok": False, "error": str(exc)})
            print(f"poll HTTP {exc.code}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            write_status({"ok": False, "error": str(exc)})
            print(f"poll failed: {exc}", file=sys.stderr)
        time.sleep(interval)


def cmd_status(args):
    conf = load_conf()
    print(f"endpoint : {conf['endpoint']}")
    print(f"node_id  : {conf['node_id']}")
    try:
        body = claim(conf)
        print(f"check-in : ok ({json.dumps(body)[:120]})")
    except Exception as exc:  # noqa: BLE001
        print(f"check-in : FAILED ({exc})")
        sys.exit(1)


def cmd_self_test(args):
    conf = load_conf()
    failures = 0
    try:
        with open(OPS_PHP) as fh:
            fh.read(1)
        print("ops.php     : readable")
    except OSError:
        print("ops.php     : MISSING")
        failures += 1
    try:
        code, result = run_op("snapshot", {})
        print(f"snapshot    : exit={code} keys={list(result)[:6]}")
        failures += 0 if code == 0 else 1
    except Exception as exc:  # noqa: BLE001
        print(f"snapshot    : FAILED ({exc})")
        failures += 1
    try:
        claim(conf)
        print("cloud claim : ok")
    except Exception as exc:  # noqa: BLE001
        print(f"cloud claim : FAILED ({exc})")
        failures += 1
    sys.exit(1 if failures else 0)


def main():
    parser = argparse.ArgumentParser(description="EchoGuard connector agent")
    parser.add_argument("--interval", type=int, default=10, help="seconds between polls")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run")
    sub.add_parser("status")
    sub.add_parser("self-test")
    args = parser.parse_args()
    if args.cmd == "run":
        cmd_run(args)
    elif args.cmd == "status":
        cmd_status(args)
    elif args.cmd == "self-test":
        cmd_self_test(args)


if __name__ == "__main__":
    main()
