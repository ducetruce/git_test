# Roadmap

## Next: get the first build running

1. `cd NarwalKit && swift test`. Fix any compile errors (this code had no
   compiler when it was written). All tests should pass, because the fixtures
   come from a client known to work.
2. Run the app against `tools/fake_robot.py` in the Simulator.
3. Run it against the real Z10 Ultra. Check that discovery, status, map, and a single-room
   clean work. Settings → Diagnostics → Connection log has a share button
   for sending logs back.

## Features that need decoding first

These exist on the robot but their payloads are unknown:

| Feature | Robot topic(s) | What a capture needs to show |
|---|---|---|
| Schedules | `schedule/clean_schedule/get`, likely a `set` | Create, edit, and delete a schedule in the Narwal app |
| Volume, do-not-disturb, carpet boost, etc. | `config/get`, `config/set`, `config/volume/set` | Flip each setting once, one at a time |
| No-go zones / virtual walls | probably `map/*` edit topics | Add one zone, then delete it |
| Room split / merge / rename | probably `map/*` edit topics | One rename, one split, one merge |
| Zone (rectangle) cleaning | `clean/start_clean`, `ZoneOption{1: 2}` | Clean one drawn rectangle |
| Cleaning history | unknown | Open the history screen |
| Reset consumable | `consumable/reset_consumable_info` | Reset one part's counter |

### How to capture the official app (iPhone + Mac)

The Narwal app talks to the robot over the same local WebSocket, so its
traffic can be recorded from a Mac:

1. Connect the iPhone to the Mac by USB. Find its UDID in Finder or
   `xcrun xctrace list devices`.
2. `rvictl -s <UDID>`. This creates a virtual interface `rvi0` that mirrors the
   phone's traffic.
3. In Wireshark, capture on `rvi0` with the filter `tcp.port == 9002`.
4. In the Narwal app, do **one** action (for example, change the volume from 5 to 6). Wait 5
   seconds, then do the next action. Note the time of each action.
5. Stop and save the `.pcapng`. Then run `rvictl -x <UDID>`.

Each action shows up as a WebSocket binary message whose topic names the
feature. Comparing two captures that differ in a single setting reveals
the field. That's how the clean-route field was found.

## Larger ideas

- **Home hub for closed-app notifications.** A tiny always-on service (it could reuse
  NarwalKit on a Mac mini, or a Python port on a Pi) that watches the robot and
  pushes alerts through self-hosted ntfy. Still no cloud.
- **"Clean when docked" queue.** Room cleans only start from the dock. The app could
  send the robot home, wait for it to dock, then start the queued clean
  instead of showing an error.
- **Verify the running task.** After starting a clean, read
  `clean/current_clean_task/get` and confirm that the robot's room list matches
  the one sent.
- **Home screen widget and Siri Shortcuts** for routines (App Intents).
