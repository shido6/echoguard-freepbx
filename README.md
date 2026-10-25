# Echo connector for FreePBX

Connect a FreePBX phone system to [Echo](https://echo.echoguard.ca) so its call
signalling shows up in your account — **outbound only, signalling only, no
audio, no inbound ports, no shell**.

```
FreePBX box ──(res_hep copy)──▶ 127.0.0.1 ──(outbound HTTPS)──▶ echo.echoguard.ca
```

This repository is a FreePBX-shaped wrapper around Echo's own connector. The
connector itself — the part that configures Asterisk's HEP copy, runs the local
helper, and heartbeats to Echo — is downloaded from
`echo.echoguard.ca/connector/connect.sh` and verified against the published
`manifest.json` before it runs. This repo adds the FreePBX admin page and a
safer wrapper around that download.

**Guides:** [Admin guide](docs/ADMIN-GUIDE.md) (install, verify, troubleshoot)
· [User guide](docs/USER-GUIDE.md) (connect once, then read your calls in Echo)

## What you get

Once connected, the box appears in the **phone systems** panel of your Echo
page as a node with the name you chose. For that node Echo shows:

| In your account | Meaning |
| --- | --- |
| **last seen** | the connector is heartbeating (~30s) |
| **last signal** | the last SIP message the box captured |
| **events** | total signalling messages forwarded |
| **version / platform** | what the box reports about itself |

That is the whole node record Echo keeps — name, platform, last seen, last
signal, events, version, and who created it. The FreePBX page shows the same
fields locally, so an admin can tell whether the two agree.

From the events Echo can show registrations, call setup, failed calls, and
trunk behaviour in plain words. Signalling only: no RTP, no audio, no
recordings, never written to disk on the way through.

## Install

1. Sign in to [Echo](https://echo.echoguard.ca) and press **+ Connect a phone
   system**. Name it (e.g. `office-pbx`) and press **Generate the one-line
   setup**. The line prints `curl ... | bash -s -- 'EC-xxxxxxxx.<64 hex chars>'`
   — the quoted part is the key. It is shown **once** (Echo keeps only its
   SHA-256 hash) and it expires after 24 hours if unused.
2. On the FreePBX server:

```bash
tar xzf echoguard-freepbx-0.2.0.tar.gz && cd echoguard-freepbx
sudo ./install.sh 'EC-xxxxxxxx.<64 hex chars>'
```

The installer:

1. downloads `connect.sh` and refuses to run it unless its SHA-256 matches
   `https://echo.echoguard.ca/connector/manifest.json`,
2. hands your key to it — that is what writes `/etc/asterisk/hep.conf`
   (inside marked blocks, so re-runs are clean), installs
   `/opt/echo-connector/`, and starts `echo-connector.service`,
3. loads `res_hep.so` / `res_hep_pjsip.so` if Asterisk has not already, and
   tells you if they are still not loaded,
4. installs the **Connectivity → Echo connector** page into FreePBX and
   registers it with `fwconsole ma installlocal`,
5. writes `/var/lib/echo-connector/node.json` so the page can show the node
   without ever reading the key.

Status appears in your account within ~30 seconds.

### Verified on a real FreePBX

Run against FreePBX 17.0.33.2 / Asterisk 22 in a Debian 12 lab, not a mock:
the stock disabled `hep.conf` was adopted with a backup, `res_hep_pjsip.so` was
loaded (FreePBX ships it idle), the connector's self-test was accepted by Echo,
three SIP OPTIONS produced six forwarded events, `fwconsole reload` left the
capture block and the running service intact, and the page rendered as the
`asterisk` web user with live node id and counts.

## Dry run and verification

```bash
./install.sh --check-only              # fetch + verify the upstream installer, change nothing
sudo ./install.sh 'EC-...' --dry-run   # show every change the connector would make
```

## The FreePBX page

**Admin → Connectivity → Echo connector** is read-only. It shows the node id,
platform, service state, last report, last captured signal, forwarded event
count and error count, and the one-line instructions for connecting another
box. It never reads the node key (that file is root-only anyway).

## Remove

```bash
sudo ./uninstall.sh
```

That asks the upstream connector to remove the systemd unit, `/opt/echo-connector`
(and the key with it) and to restore the `hep.conf` backup, then deletes the
FreePBX page and `/var/lib/echo-connector`. Logs in `/var/log/echo-connector/`
are left for audit; delete them yourself when you no longer want the trail.
Finally, **Remove** the node in Echo so the key cannot be reused.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `could not fetch the manifest` | no outbound HTTPS to `echo.echoguard.ca` | `curl -sI https://echo.echoguard.ca/connector/manifest.json` from the box |
| `integrity check failed` | stale or tampered copy behind a cache | retry; do not bypass the check |
| `Echo did not recognize the node key` | key revoked, or mistyped | generate a fresh setup string in Echo and re-run |
| install stops: "already forwards signals somewhere else" | `hep.conf` has a *live* capture from someone else | re-run with `--adopt-existing` (backup is kept in `/var/backups/echo-connector/`) |
| install says "adopting it (backup kept)" | stock FreePBX/Debian `hep.conf` (`enabled = no`) | nothing to do — the installer replaces the disabled sample and keeps the original |
| node shows connected, `events` stays at 0 | `res_hep*` not loaded | `asterisk -rx 'module load res_hep.so'`, same for `res_hep_pjsip.so`; check `noload=` in `modules.conf` |
| node goes quiet | service stopped or no outbound path | `systemctl status echo-connector`, `tail /var/log/echo-connector/agent.log` |

## Security model

- **Outbound only.** The connector opens no listening ports on a public
  interface; Asterisk copies to `127.0.0.1`, and the helper dials out over 443.
- **One-time key**, stored only as `sha256(key)` on Echo's side, in a
  600-mode `agent.env` on the box. Revoking the node rejects it on the next
  heartbeat.
- **Verified installer.** `install.sh` checks the upstream script against the
  published manifest before executing it; the upstream script re-checks its own
  embedded payloads the same way.
- **Reversible.** Every config change is inside marked blocks with a backup in
  `/var/backups/echo-connector/`.
- **What it never touches:** audio, recordings, CDRs, the FreePBX database,
  dialplans, or extensions.

## Layout

| Path in this repo | Purpose |
| --- | --- |
| `install.sh` | wrapper: verify, run the upstream connector, install the page |
| `uninstall.sh` | delegate removal upstream, then remove the page and state |
| `module.xml`, `page.echoguard.php` | the FreePBX admin page |
| `docs/ADMIN-GUIDE.md`, `docs/USER-GUIDE.md` | the two guides |

## Built on the shoulders of giants

The capture rides **HEP**, the open capture protocol from the
[sipcapture project](https://sipcapture.org/) — the same open plumbing behind
[HOMER](https://github.com/sipcapture/homer) (100% open source) and
[hepic](https://hepic.tel) (QXIP's carrier-grade stack), catalogued in
[awesome-hep](https://github.com/sipcapture/awesome-hep). We didn't invent the
standard, we don't ship their code, and nothing here is branded "Hepic" or
"HOMER" — those names belong to their projects. No affiliation, sponsorship,
or endorsement is implied. FreePBX and Asterisk are their respective projects'
trademarks; this is an independent, community connector.

## License

MIT — see [LICENSE](LICENSE).
