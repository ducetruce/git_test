# Narwal Local

A private iPhone app for the **Narwal Freo Z10 Ultra** that talks to the robot
directly over your home Wi-Fi. There's no Narwal account, no cloud, and no Home Assistant.

```
iPhone app  ──ws://robot:9002──▶  Freo Z10 Ultra
(SwiftUI)     protobuf frames     (same Wi-Fi)
```

> **Status: first build, not yet run on hardware.** The protocol layer is
> checked byte-for-byte against a community client that is confirmed working
> on the Z10 Ultra (CX4). The Swift code was written in an environment without
> a Swift compiler, so the first `swift test` / Xcode build on your Mac is the
> first compile. Expect a few small fixes.

## What works

| Area | Status |
|---|---|
| Find the robot (Bonjour) or enter its IP | ✅ |
| Live status: state, battery, docked/charging, errors, tanks | ✅ |
| Start/pause/resume/stop, return to dock, locate, quick clean | ✅ |
| **Room cleaning in the order you tap**, with per-room settings | ✅ |
| Whole-house clean with chosen mode/suction/water/passes/route | ✅ |
| Live map: rooms, dock, robot position, driven path | ✅ |
| Live suction/water changes mid-clean | ✅ |
| Station: wash/dry mop, empty dustbin, dry bags, station light | ✅ |
| Maintenance alerts (which parts need cleaning/replacing) | ✅ |
| Saved routines (one-tap room + settings combos) | ✅ |
| Local notifications: errors, tank problems, clean finished, maintenance | ✅ while the app is open or recently backgrounded |

## Bugs this fixes compared with the Narwal app

These come from issues the community found in the Narwal app and in earlier
local integrations:

- **Live map freezing mid-clean.** The robot only streams position while a
  topic subscription is active, and that subscription quietly expires after 10
  minutes. NarwalKit renews it every 8 minutes. It also detects a stalled position
  feed during a clean and re-subscribes. (`NarwalConnection.keepaliveLoop`)
- **Room cleans running the wrong rooms.** `clean/plan/start` runs the robot's
  stored plan and silently ignores the rooms you send. This app always uses
  `clean/start_clean`, cleans rooms in the order you pick, and builds every task
  against a freshly fetched map. A stale map id has been seen to abort jobs and
  wipe the map selection. It also refuses rooms that aren't on the current map
  instead of sending them. (`Commands.cleanRooms`)
- **Wrong replies matched to commands.** Robot replies don't say which command
  they answer. Commands are matched strictly in send order, and late replies to
  timed-out commands are discarded, never handed to the next command.
- **Phantom and repeated alerts.** An alert must persist for two consecutive
  status reports before it fires. Each condition notifies once until it clears,
  and a missing reading shows as *Unknown*, never as *OK* or *problem*.
  (`AlertMonitor`)
- **"Docked" while actually cleaning.** Newer firmware reports a docked code
  while cleaning off the dock. The app reads the extra sub-field that tells
  the two apart.
- **Robot disconnecting after a minute.** The robot drops idle sockets after 60 s.
  The app sends the heartbeat the robot actually counts, every 15 s.

## Building it (on your Mac)

You need a Mac with Xcode 15 or later. A free Apple ID can install the app on your own
iPhone, but the install expires after 7 days and must be re-run from Xcode. A paid
developer account ($99/yr) makes it last a year.

```bash
# 1. Run the protocol tests first: they prove the Swift encoders match the
#    known-good reference byte-for-byte.
cd NarwalKit && swift test

# 2. Generate the Xcode project
brew install xcodegen
cd ../App && xcodegen
open NarwalLocal.xcodeproj
```

In Xcode: select the **NarwalLocal** target, then **Signing & Capabilities**.
Choose your team and change the bundle identifier to something unique, such as
`com.yourname.narwal`. Plug in your iPhone and press Run.

On first launch, iOS asks for **Local Network** access. Allow it, or the app
can't see the robot. (Settings → Privacy & Security → Local Network if you
missed it.)

### Try it without the robot

`tools/fake_robot.py` pretends to be a Z10 Ultra with a three-room map. It
answers commands, streams status, and drives around during a clean.

```bash
pip3 install websockets
python3 tools/fake_robot.py
```

In the iOS Simulator, enter `127.0.0.1`. On a real phone, enter your Mac's IP address.
Every frame the app sends is printed, which also makes this a good debugging
tool.

## Layout

```
NarwalKit/            Swift package: the protocol, no UI. Unit-tested.
  Protobuf.swift      schema-less protobuf reader/writer
  Frame.swift         the 4-byte header + topic + payload framing
  NarwalConnection    socket, reconnects, reply matching, wake & keepalive
  Commands.swift      high-level actions (clean rooms, dock, station…)
  Models.swift        status, progress, pose, consumables decoders
  RobotMap.swift      map decoding (zlib grid, rooms, dock, coordinates)
App/                  SwiftUI app (XcodeGen spec in project.yml)
tools/
  gen_golden_vectors.py  regenerates test fixtures from the reference client
  fake_robot.py          protocol-accurate robot simulator
```

## Not possible yet, and why

- **Notifications when the app is closed.** iOS only lets an app keep a local
  socket open briefly in the background, and push notifications need a server.
  To get alerts with the app closed and still no cloud, you'd add a small
  always-on box at home (Raspberry Pi, NAS) that watches the robot and sends
  notifications through a self-hosted service such as ntfy. This is a good next step if you want it.
- **Schedules stored on the robot, no-go zones, virtual walls, map editing
  (split/merge/rename rooms), cleaning history, voice volume.** The robot has
  topics for several of these (`schedule/clean_schedule/get`, `config/*`), but
  nobody has decoded their payloads yet. Decoding them takes captures of the
  official app's traffic. A capture plan is in
  [docs/ROADMAP.md](docs/ROADMAP.md).
- **Consumable life percentages and firmware updates** appear to come only
  from Narwal's cloud.
- **Camera images** are encrypted with a key nobody has found yet.

## Security note

The robot's local port has **no authentication**. Anything on your Wi-Fi can
control it, and one known command returns your **Wi-Fi password in plain text**.
Put the robot on a separate IoT network or VLAN, and allow your phone to reach
port 9002 on it.

## Credits

The protocol knowledge comes from the community project
[NarwalIntegration](https://github.com/sjmotew/NarwalIntegration) (MIT). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This app is not affiliated with Narwal.
