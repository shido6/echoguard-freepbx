# EchoGuard connector — User guide (running it from your EchoGuard console)

This guide is for the person who **uses** the connector — you connect your
FreePBX system once, then ask EchoGuard for a snapshot, a diagnosis, or a
reload without logging into the phone system. Server-side install details
are in [ADMIN-GUIDE.md](ADMIN-GUIDE.md).

## 1. The 30-second version

1. **Connect once:** add your FreePBX system in the console, copy the
   one-line setup command, paste it on your server (needs sudo), done.
2. **Ask for a look:** request a **snapshot** (how things are) or a
   **diagnose** (what looks off) any time.
3. **Ask for a reload** when you've made changes and need them to take effect.
4. **Revoke** whenever you want the connection gone.

No inbound ports. No shell access. Your server calls out; nothing calls in.

## 2. Connecting a system

1. In your EchoGuard console, go to **Phone systems → Add FreePBX**.
2. Give it a name (e.g. `office-pbx`) and copy the setup command:

   ```
   sudo ./install.sh --endpoint https://app.echoguard.ca --node 3 --key <one-time-key>
   ```

3. On your FreePBX server (SSH, one time):

   ```bash
   tar xzf echoguard-freepbx-0.1.0.tar.gz && cd echoguard-freepbx
   sudo ./install.sh --endpoint https://app.echoguard.ca --node 3 --key <one-time-key>
   ```

4. Back in the console, the system turns **online** within ~15 seconds.

That key is shown once and only its fingerprint is stored on our side. If it
ever leaks, revoke the system and add it again — a fresh key, one command.

## 3. What you can ask for

| Request | Plain-English meaning | Good for |
| --- | --- | --- |
| **Snapshot** | "Show me what this system is running and how busy it is" — FreePBX/Asterisk versions, active calls, uptime, disk space | A quick health look; before/after changes |
| **Diagnose** | "What looks off?" — SIP registrations (registered vs rejected), disk pressure, plain-language hints | "Phones won't register" style questions |
| **Reload** | "Apply the configuration" (standard FreePBX/Asterisk reload) | After you changed something in the GUI |
| **Reload one module** | Reload a single piece: core, pjsip, ivr, timeconditions, ringgroups, queues, miscapps, customappctx, confirm, findmefollow | A lighter touch than a full reload |

Everything else is off the table on purpose: no shell, no dialplan edits, no
database access, no recordings or audio.

## 4. Running a command today

While the console panel for this is rolling out, commands go through the
console API with your normal console token. Example with `curl`:

```bash
# list your connected systems
curl -s -H "Authorization: Bearer $TOKEN" \
  https://app.echoguard.ca/api/fpbx/nodes

# ask for a snapshot
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"op":"snapshot"}' \
  https://app.echoguard.ca/api/fpbx/nodes/1/commands

# read the result (a second or two later)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://app.echoguard.ca/api/fpbx/nodes/1
```

The node detail response carries the last commands with their status
(`pending → done/error`), exit code, and the result JSON. The agent polls
every ~10 seconds, so results appear within one or two poll cycles.

To reload a single module:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"op":"module_reload","module":"pjsip"}' \
  https://app.echoguard.ca/api/fpbx/nodes/1/commands
```

An unknown op or a module outside the allowlist is rejected immediately with
the list of what's allowed — nothing reaches your phone system.

## 5. Reading a diagnose result

A diagnose result is numbers plus hints, for example:

```json
{
  "registrations_registered": 4,
  "registrations_bad": 1,
  "disk_root_used_pct": 61,
  "asterisk_responds": true,
  "hints": ["One or more SIP registrations are rejected/unregistered — check trunk credentials and network reachability."]
}
```

How to read it:

- **registrations_bad > 0** — something isn't staying registered: trunk
  credentials, a blocked IP, or your carrier. This is the classic "inbound
  calls stopped working" cause.
- **disk_root_used_pct ≥ 90** — the box is nearly full; recordings and
  logs will start failing soon.
- **asterisk_responds: false** — Asterisk itself isn't answering; nothing
  else in the result can be trusted until it is back.
- **empty hints** — the checks it ran came back clean.

## 6. When to use which reload

- Changed multiple things in the FreePBX GUI → **reload**.
- Changed one thing (e.g. a PJSIP trunk) and want the smallest possible
  interruption → **module_reload** on that module.
- Nothing changed → don't reload. A reload drops nothing on a healthy box,
  but there's no reason to poke it for fun.
- Phones are dropping calls mid-conversation? Don't reload from here —
  that's live traffic; treat it as an incident and get on the box.

## 7. Disconnecting

**Phone systems → the system → Revoke.** The agent's next poll gets a 401
and stops itself. Nothing is left usable: the key dies server-side, and
running `sudo ./uninstall.sh` on the box removes every file the installer
added.

## 8. Limits and roadmap (no surprises)

**Today (v0.1):** snapshot · diagnose · reload · module_reload (fixed module
list) · outbound-only agent · one-time key · instant revoke.

**Not today:** editing routes/destinations/dialplans (coming behind strict
schema validation — never free-form SQL), SIP signaling mirroring (separate
Echo HEP lane, signaling only), multi-agent boxes.

**Never:** free-form shell, audio/recordings, database writes.

## 9. FAQ

**Does anything connect inbound to my server?**
No. The agent dials out over HTTPS every ~10 seconds. Your firewall needs
no new openings.

**Can this break my phone system?**
`reload` and `module_reload` are the same commands you'd run by hand in the
GUI. They don't edit configuration — they apply what's already there. The
ops that could misbehave (routing edits) aren't in v0.1 at all.

**What if my internet drops?**
The agent retries until it's back; the console shows the node offline while
disconnected. Your phone system never depends on the connection.

**Who else can control this?**
Whoever holds a console login for your tenant — same trust model as the
rest of your console. Revoke the node to cut everyone off instantly.

**Where's the setup key stored on your side?**
Only as a SHA-256 hash. It can't be read back — if you lose it, you revoke
and re-add to get a fresh one.
