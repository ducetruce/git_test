# Continuing on the Mac

Notes for a Claude session running on the owner's Mac, which is on the same
Wi-Fi as the robot (a cloud session can't reach it). Read the README first.

## Where things stand

- The iPhone app connects to the Freo Z10 Ultra and its commands work.
- Z10 Ultra specifics learned the hard way: commands must carry the robot's
  device ID (shown in the app under Settings, also in its connection log);
  another model's product key makes it hang up; it accepts one connection
  per source IP and refuses reconnects for ~10 s after dropping one.
- Read-side decoding is the next job: settings, schedules, no-go zones,
  room edits, cleaning history (table in `docs/ROADMAP.md`).

## 1. Snapshot and diff from the Mac

`tools/narwal_lab.py` sends only read-only queries (it refuses anything
else, and never sends `developer/get_robot_info`, which returns the Wi-Fi
password).

```bash
python3 -m venv .venv && .venv/bin/pip install websockets
.venv/bin/python tools/narwal_lab.py snapshot baseline --host <robot IP> --device-id <id>
# owner changes ONE setting in the Narwal app (e.g. voice volume 5 -> 6)
.venv/bin/python tools/narwal_lab.py snapshot volume6 --host <robot IP> --device-id <id>
.venv/bin/python tools/narwal_lab.py diff baseline volume6
```

The Mac has its own IP, so this can stay connected while the Narwal app on
the phone is in use. Confirm each finding with a second value (6 -> 3).
Snapshots go to `tools/lab_snapshots/`, which is git-ignored; they describe
the owner's home, so don't commit them.

If computer use and iPhone Mirroring are available, the session can make
the Narwal app changes itself; otherwise the owner does them on request.

## 2. Capture the Narwal app's own commands (write side)

Reading a setting doesn't say how to change it. With the iPhone on USB,
unlocked and trusted:

```bash
.venv/bin/pip install pymobiledevice3
sudo .venv/bin/pymobiledevice3 pcap --out narwal.pcap   # Ctrl-C after one action
```

Do one action in the Narwal app per capture. Frames to/from port 9002 are
the local protocol (see `NarwalKit/Sources/NarwalKit/Frame.swift`);
client-to-server WebSocket frames are masked. The sytchi fork's
`tools/decode_ws_pcap.py` is a working decoder to adapt. `rvictl` is
reported broken on recent macOS, hence pymobiledevice3. Captures contain the
device ID: keep them out of git.

## 3. Turning findings into features

- Add the decoded fields to NarwalKit with a golden-vector test, as for
  the existing payloads (`tools/gen_golden_vectors.py`).
- Writes go out one harmless setting at a time, confirmed in the Narwal app.
- Push to `narwal-local-app`; CI runs unit tests, three fake-robot
  end-to-end tests and a Simulator launch, then produces the IPA.

## Building on the Mac instead of Signulous

`brew install xcodegen && cd App && xcodegen && open NarwalLocal.xcodeproj`,
set the signing team, change the bundle ID, run on the phone.
