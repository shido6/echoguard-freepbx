# Echo connector — Admin guide (FreePBX administrator)

For the person who administers the FreePBX server: install, verify, secure,
and fix. A non-technical walkthrough of what the phone system owner sees is in
[USER-GUIDE.md](USER-GUIDE.md).

## 1. What this is (and isn't)

| It is | It is not |
| --- | --- |
| A copy of your SIP signalling into your own Echo account | Audio, recordings, or CDR export — ever |
| Outbound only: Asterisk copies to `127.0.0.1`, the helper dials out over 443 | Anything listening for inbound connections |
| Three config changes, each inside a marked block with a backup | A rewrite of your dialplan, trunks, extensions, or database |
| Removable in one command, leaving backups intact | A one-way door |

The box appears in Echo as a **node** with a name you chose. Echo shows when it
last reported, when it last captured a signal, how many events it forwarded,
and the version/platform it reports.

## 2. Requirements

- FreePBX with `fwconsole` working (14+ expected).
- Asterisk `res_hep.so` and `res_hep_pjsip.so` present. On FreePBX these ship
  with Asterisk but are often idle; the installer loads them if needed. They
  must not be listed under `noload=` in `/etc/asterisk/modules.conf`.
- `python3`, `curl`, `sha256sum` — all present on a normal FreePBX box.
- Outbound HTTPS 443 to `echo.echoguard.ca`. No inbound rules at all.
- Root for install (`systemd`, `/etc/asterisk`, `/opt`).

## 3. Install

### Step 1 — create the node

Sign in to **https://echo.echoguard.ca** and press **+ Connect a phone
system**. Name it (e.g. `office-pbx`) and press **Generate the one-line
setup**. Echo prints:

```
curl -fsSL https://echo.echoguard.ca/connector/connect.sh | bash -s -- 'EC-7f3a9c21.<64 hex chars>'
```

The quoted part is the key. You can paste that whole line, or use this repo's
`install.sh` with just the quoted part — same result, with the FreePBX page and
the integrity check added.

The key is shown **once** and expires after 24 hours if it is never used. Echo
stores `sha256(key)` only, so it is not recoverable — if it is lost, remove the
node and create a new one.

### Step 2 — run the wrapper

```bash
tar xzf echoguard-freepbx-0.2.0.tar.gz
cd echoguard-freepbx
sudo ./install.sh 'EC-7f3a9c21.<64 hex chars>'
```

What happens, in order:

1. `install.sh` fetches `connect.sh` and `manifest.json`, and **stops** if the
   SHA-256 of `connect.sh` does not match the published value. Nothing is
   executed on a mismatch.
2. The upstream connector verifies its embedded payloads the same way, then
   calls `/api/nodes/heartbeat` to confirm the key and learn its node id.
3. It writes `/etc/asterisk/hep.conf` — inside
   `; echoguard-connector begin/end` markers — pointing capture at
   `127.0.0.1:<port>`, backing up any existing file to
   `/var/backups/echo-connector/`.
4. It installs `/opt/echo-connector/connector.py` and
   `/opt/echo-connector/agent.env` (mode **600**), creates the system user
   `echo-agent`, and enables `echo-connector.service`.
5. It runs a self-test: a synthetic event to Echo. If Echo does not see it, the
   install says so instead of pretending.
6. `install.sh` loads `res_hep.so` / `res_hep_pjsip.so` if they were idle and
   prints the result.
7. It installs the FreePBX page into
   `/var/www/html/admin/modules/echoguard/` and writes
   `/var/lib/echo-connector/node.json` (0644, node id and platform only).

### Step 3 — confirm

```bash
systemctl status echo-connector
tail -n 40 /var/log/echo-connector/agent.log
python3 /opt/echo-connector/connector.py --status
```

`--status` prints the endpoint, listen address, last captured signal, last
successful send, total events and error count as JSON.

In Echo, the node turns from *never seen* to *last seen seconds ago*. Then place
a test call — `events` should climb within a second or two.

## 4. The FreePBX page

**Admin → Connectivity → Echo connector**, also reachable as
`config.php?display=echoguard`. Read-only:

- node id, platform, endpoint, installed-at
- service state (`systemctl is-active echo-connector`)
- last report, last captured signal, forwarded events, send errors

It reads `/var/lib/echo-connector/{node,state}.json` as the web user. It never
reads `agent.env`, because that file is root-only and contains the key.

## 5. Day-2 operations

| Task | How |
| --- | --- |
| Health | `sudo python3 /opt/echo-connector/connector.py --status` |
| Live log | `tail -f /var/log/echo-connector/agent.log` |
| Audit trail | `/var/log/echo-connector/audit.log` (every config change, with timestamps) |
| Restart | `sudo systemctl restart echo-connector` |
| Pause capture | `sudo systemctl stop echo-connector` (Asterisk keeps copying to loopback; nothing is lost to the network) |
| Rotate key | Remove the node in Echo, connect it again, re-run `install.sh` with the new key |
| Upgrade | Unpack the new version and re-run `install.sh` with the **existing** key — re-runs are idempotent inside the markers |
| Remove | `sudo ./uninstall.sh`, then **Remove** the node in Echo |

## 6. Security model (for your auditor)

- **No inbound surface.** The helper listens on `127.0.0.1` only. Asterisk
  sends HEPv3 UDP to loopback; the helper batches and posts outbound over TLS.
- **Key handling.** `agent.env` is `0600 root` on the box, `sha256(key)` on the
  server, compared constant-time. Revocation takes effect on the next
  heartbeat.
- **Runs unprivileged.** The service runs as `echo-agent`, with
  `ReadWritePaths` limited to `/var/log/echo-connector` and
  `/var/lib/echo-connector`.
- **Verified chain.** Wrapper → manifest → `connect.sh` →
  embedded `connector.py` and platform examples. Each link is a SHA-256 pin.
- **Reversible.** Marked blocks, backups in `/var/backups/echo-connector/`,
  and `--uninstall` restores the newest backup per file.
- **What it can see:** SIP headers and SDP of signalling — numbers, trunk
  names, timing, failure causes. **Never** RTP payload, audio, recordings,
  voicemail, the Asterisk database, or your dialplan source.

## 7. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Echo did not recognize the node key` | removed, mistyped, or older than 24 hours | generate a new setup line, re-run |
| `could not reach Echo at https://echo.echoguard.ca` | no outbound 443 / proxy / DNS | `curl -sI https://echo.echoguard.ca/connector/manifest.json` |
| `integrity check failed` | stale cache or tampering | retry from a clean shell; never bypass |
| `this phone system already sends its signals somewhere else` | existing `hep.conf` from another capture | re-run with `--adopt-existing`; compare `/var/backups/echo-connector/` after |
| Node connected, `events: 0` | `res_hep*` not loaded, or `noload=` | `asterisk -rx 'module show like res_hep'`; load both modules; remove `noload=res_hep` lines |
| `events` climbs on outbound calls only | capture id / uuid type mismatch | confirm `capture_id` in `hep.conf` matches `python3 /opt/echo-connector/connector.py --status` |
| Service flaps | port taken by an older install | `ss -lunp \| grep <port>`; remove the stale process, then restart |
| Page says *Quiet* but service is active | no signals since install | that is normal until the first call; place a test call |
| Page says *Not connected* | `node.json` missing | re-run `install.sh` (it rewrites it) |

## 8. Files installed on the box

```
/etc/asterisk/hep.conf                    capture block (marked, backed up)
/opt/echo-connector/connector.py          helper
/opt/echo-connector/agent.env             key + endpoint + listen (600)
/opt/echo-connector/example-*.txt         platform example, if requested
/etc/systemd/system/echo-connector.service
/var/lib/echo-connector/state.json        counters written by the helper
/var/lib/echo-connector/node.json         node id for the FreePBX page
/var/log/echo-connector/{agent,audit}.log
/var/backups/echo-connector/*.bak         originals before each change
/var/www/html/admin/modules/echoguard/    this repo's FreePBX page
```

`uninstall.sh` removes everything except `/var/log/echo-connector/` and
`/var/backups/echo-connector/`, which are kept for audit.

## 9. Limits, stated honestly

- Signalling only. No audio, no recordings, no CDR bulk import.
- One connector per box; the loopback listener is single-instance.
- FreePBX regenerates `pjsip.conf` and `sip.conf` on apply, but it does not
  manage `hep.conf` — the capture block survives `fwconsole reload`.
- Echo reads and explains; it does not edit your dialplan or destinations.
