# EchoGuard connector — Admin guide (FreePBX administrator)

This guide is for the person who administers the FreePBX server. It covers
installing the connector, verifying it, securing it, and fixing it when
something looks wrong. A non-technical walkthrough of running commands from
the EchoGuard side is in [USER-GUIDE.md](USER-GUIDE.md).

## 1. What this connector is (and isn't)

| It is | It is not |
| --- | --- |
| An outbound-only agent: your box calls `https://app.echoguard.ca` and asks "any work for me?" | A remote-access backdoor — no inbound ports, no SSH, no VPN |
| A small allowlist of named operations (snapshot, diagnose, reload, module_reload) | Free-form shell — there is no "run this command" path, by design |
| A one-time setup key, stored hashed server-side | Long-lived shared secrets in the console |
| Something you can remove in one command | Something that modifies dialplans or the database (v0.1 has no schema/route edits) |

## 2. Requirements

- FreePBX with `fwconsole` working (14+ expected; tested against the standard
  Debian-based distributions).
- `python3` (3.8+) — agent is stdlib-only, no pip installs.
- `php` CLI (already present on every FreePBX box).
- Outbound HTTPS (443) to `app.echoguard.ca`. No inbound connectivity at all —
  if the box can browse the web, it can run this agent.
- Root on the box for install (systemd + `/usr/local` writes).

## 3. Install

**Step 1 — get the setup command.**
In your EchoGuard console, add a FreePBX system. The console prints a
one-line command shaped like:

```
sudo ./install.sh --endpoint https://app.echoguard.ca --node 3 --key <one-time-key>
```

The key is shown **once**. Only its SHA-256 hash is stored on our side.

> Console panel note: while the console panel is rolling out, the same setup
> command is returned by the console API `POST /api/fpbx/nodes`
> (`setup_command` field) using your console token.

**Step 2 — run the installer.**

```bash
tar xzf echoguard-freepbx-0.1.0.tar.gz
cd echoguard-freepbx
sudo ./install.sh --endpoint https://app.echoguard.ca --node 3 --key <key>
```

The installer:

1. copies the agent to `/usr/local/bin/echoguard-agent` and the op executor
   to `/usr/local/lib/echoguard/echoguard_ops.php`
2. writes `/etc/echoguard/agent.conf` (mode **600**, root-owned)
3. installs + enables + starts `echoguard-agent.service`
4. runs a self-test and fails the install loudly if anything is off

**Step 3 — confirm.**

```bash
sudo echoguard-agent status      # prints endpoint, node id, check-in result
sudo echoguard-agent self-test   # local ops + cloud claim in one pass
journalctl -u echoguard-agent -n 50 --no-pager
```

The system shows `online` in your EchoGuard console within ~15 seconds.

## 4. Optional: the FreePBX GUI page

The agent works with or without the GUI. For a settings/status page inside
the FreePBX admin UI:

```bash
sudo mkdir -p /var/www/html/admin/modules/echoguard
sudo cp module.xml page.echoguard.php /var/www/html/admin/modules/echoguard/
# then: Module Admin → reload (or fwconsole reload)
```

The page shows check-in status and explains the allowlisted operations; it
does not need to be present for the agent to run.

## 5. Day-2 operations

| Task | How |
| --- | --- |
| Check health | `sudo echoguard-agent status` |
| Watch activity | `journalctl -u echoguard-agent -f` |
| Restart | `sudo systemctl restart echoguard-agent` |
| Stop temporarily | `sudo systemctl stop echoguard-agent` (console shows node as offline after the idle window) |
| Rotate the key | Revoke the node in the console, add the system again, re-run the new setup command |
| Upgrade | Unpack the new version, re-run `install.sh` with your existing endpoint/node/key |
| Uninstall | `sudo ./uninstall.sh`, then revoke the node in the console |

## 6. Security model (what to tell your auditor)

- **Outbound only.** The agent opens no listening sockets. Firewall rules
  need nothing inbound; only outbound 443 to `app.echoguard.ca`.
- **One-time node key** in `/etc/echoguard/agent.conf` (600). Server stores
  only `sha256(key)` and compares with `timingSafeEqual`.
- **Revocation is instant.** Revoke in the console → next agent request gets
  `401` → the agent stops itself with a clear log line.
- **Allowlist enforced twice.** The cloud rejects unknown ops before a
  command is ever queued; the executor re-checks the same list (plus an
  explicit module list for `module_reload`) before running anything.
- **No free-form shell.** Every op maps to fixed commands (`asterisk -rx
  '…'`, `fwconsole reload <allowlisted module>`, `df`). Arguments never reach
  a shell unparsed.
- **What it can see:** versions, channel counts, registration summary, disk
  usage, uptime. What it never touches: recordings, CDRs, audio, passwords,
  the database schema.

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `missing config /etc/echoguard/agent.conf` | install.sh not run (or run without sudo) | Re-run install.sh as root |
| `claim HTTP 401 — node key rejected` | Node revoked, or key pasted wrong | Add the system again in the console; re-run the new setup command |
| `claim failed (urllib error)` | No outbound path / proxy / DNS | Test `curl -sI https://app.echoguard.ca` from the box |
| `fwconsole: not found` or ops fail with exit 127 | PATH under systemd differs | Check `which fwconsole` in a login shell; symlink into `/usr/local/bin` if needed |
| `php: not found` | Minimal install | Install the distro `php-cli` package |
| Self-test says snapshot fails | Asterisk not running | Check `systemctl status asterisk` first — the connector does not start Asterisk |
| Console shows `offline` but service running | Agent crashed on a poll loop | `journalctl -u echoguard-agent -n 100`; the service auto-restarts every 15 s |
| Want a clean slate | — | `sudo ./uninstall.sh` removes every file it added; revoke in console |

## 8. Current limits (v0.1 — stated honestly)

- No dialplan/destination/routing edits (planned behind server-side schema
  validation — never free-form SQL).
- No bulk CDR, recording, or audio access — ever, by design.
- No SIP signaling mirror from this plugin. If you also want signaling
  visibility, use the separate Echo HEP connector lane (signaling only,
  never audio).
- One agent instance per box (the loopback work path expects a single
  installed instance).

## 9. Files installed on the box

```
/usr/local/bin/echoguard-agent           agent (run / status / self-test)
/usr/local/lib/echoguard/echoguard_ops.php   bounded op executor
/etc/echoguard/agent.conf                endpoint + node id + key (600)
/var/lib/echoguard/agent-state.json       dedupe state
/var/lib/echoguard/last-status.json       last check-in (for the GUI page)
/etc/systemd/system/echoguard-agent.service
```

Everything is removed by `uninstall.sh`.
