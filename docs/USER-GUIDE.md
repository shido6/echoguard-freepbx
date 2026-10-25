# Echo connector — User guide (connecting a phone system)

For the person who **uses** the connector: you connect your FreePBX system
once, then its calls and problems show up on your Echo page in plain words.
Server-side details are in [ADMIN-GUIDE.md](ADMIN-GUIDE.md).

## 1. The 30-second version

1. **Connect once.** Press **+ Connect a phone system** on your Echo page, name
   it, and paste the one line it gives you on the phone system's computer.
2. **Ask.** Echo answers about that system in plain language — busy hours,
   failed calls, who is registered, what broke.
3. **Remove** whenever you want it gone. The key stops working immediately.

No inbound ports. No audio. Your phone system calls out; nothing calls in.

## 2. Connecting a system

1. Sign in at **https://echo.echoguard.ca**.
2. Press **+ Connect a phone system**, type a name (e.g. `office phone
   system`), and press **Generate the one-line setup**.
3. Copy the line. It looks like:

   ```
   curl -fsSL https://echo.echoguard.ca/connector/connect.sh | bash -s -- 'EC-8b11ef6c.<64 hex chars>'
   ```

4. On the FreePBX server, over SSH, one time:

   ```bash
   curl -fsSL https://echo.echoguard.ca/connector/connect.sh | sudo bash -s -- 'EC-8b11ef6c.<64 hex chars>'
   ```

   Or, if you were handed this repo's installer instead, run
   `sudo ./install.sh 'EC-...'` with the same quoted key. Either way the key is
   the part in single quotes.

5. Back on your Echo page, the system appears in the phone systems panel within
   about 30 seconds. Place a test call and the event count should move.

The key is shown once and is good for 24 hours if you do not use it. If it
expires, remove the node and generate a new line — one minute of work.

## 3. What you can see

| Panel | What it answers |
| --- | --- |
| **Last seen** | is the phone system still talking to Echo? |
| **Last signal** | the most recent call activity Echo received |
| **Events** | how much signalling has come through since install |
| **Version / platform** | what the box says it is running |

From that activity Echo can answer things like:

- "How many calls came in this morning, and how many failed?"
- "Is anything not registered right now?"
- "Which trunk is rejecting calls?"
- "What happened around 2pm yesterday?"

You can also upload a `.pcap` from the phone system and Echo will read the
signals and explain them — again, never the audio.

## 4. Reading what Echo tells you

- **"N events, including M call attempts"** — normal traffic. M is the number
  of calls that tried to set up in that window.
- **Failed calls with a SIP code** — `401/403` is a credential or permission
  problem, `408` is no answer from the far end, `503` is a carrier or trunk
  outage. Echo names the trunk involved.
- **Nothing registered** — the phone has lost its registration; usually
  credentials, a network change, or the phone itself.
- **One-way audio** — signalling looks fine on both legs; the audio path is
  the problem. Echo says so rather than blaming the call.
- **Quiet node** — no signals at all. That is a connector or `res_hep` issue on
  the box, not a phone system outage (see the admin guide's troubleshooting).

## 5. Removing a system

Two steps, in this order:

1. On the phone system: `sudo ./uninstall.sh` (or the upstream
   `... | sudo bash -s -- --uninstall`).
2. On your Echo page: press **Remove** next to the system.

Step 2 kills the key immediately, so even if the box is offline or unreachable,
removing the node is enough to stop it being accepted again.

## 6. Privacy and limits (no surprises)

- **Signalling only**: who called whom, which trunk, what failed, timing.
- **Never audio**: no RTP, no recordings, no voicemail, no call contents.
- **Never your configuration**: Echo does not read or change your dialplan,
  extensions, trunks, or database. This connector is read-only on your side.
- **Outbound only**: nothing listens for connections from the internet.
- Files uploaded for decoding (`.pcap`) are deleted after reading.

## 7. FAQ

**Does anything connect inbound to my server?**
No. The helper dials out over HTTPS. Your firewall needs no new openings.

**Can this break my phone system?**
It adds a capture instruction and a small helper. It does not edit routes,
trunks, or extensions, and `uninstall.sh` restores the original config from a
backup. Worst case is extra CPU/log noise, not lost calls.

**What if my internet drops?**
The helper retries; your phone system never depends on it. The node shows as
quiet until it reconnects, and signals during the gap are simply not sent.

**Who else can see this?**
Whoever has a login to your Echo account. Removing the node cuts it off
immediately.

**Where is the key kept?**
On the phone system in a root-only file; on Echo's side only as a hash. It
cannot be read back, which is why a lost key means generating a new one.

## 8. Where this comes from (no surprises)

The capture rides **HEP** — the open signalling-capture protocol from the
[sipcapture project](https://sipcapture.org/). If you ever want to run that
world yourself, there are two honest doors: [HOMER](https://github.com/sipcapture/homer)
(100% open source) and [hepic](https://hepic.tel/deploy/) (commercial
on-prem). The ecosystem map is
[awesome-hep](https://github.com/sipcapture/awesome-hep). None of them are us —
they built the floor we stand on. FreePBX and Asterisk are their respective
projects' trademarks; this is an independent connector.
