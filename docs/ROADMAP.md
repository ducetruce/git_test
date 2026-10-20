# Roadmap

## Next: get the first build running

1. CI (GitHub Actions) compiles everything and runs the protocol tests on
   every push. Install the IPA from the latest green run.
2. Optionally, try it against `tools/fake_robot.py` first.
3. Run it against the real Z10 Ultra. Check that discovery, status, map, and a single-room
   clean work. Settings → Diagnostics → Connection log has a share button
   for sending logs back.

## Features that need decoding first

These exist on the robot but their payloads are unknown:

| Feature | Where it probably lives | Lab experiment |
|---|---|---|
| Voice volume, do-not-disturb, carpet boost, child lock… | `config/get` | Change each setting once, one at a time |
| Schedules | `schedule/clean_schedule/get` | Add a schedule, then change its time, then delete it |
| No-go zones / virtual walls | `map/get_map` | Add one no-go zone, then add one wall |
| Room rename / split / merge | `map/get_map` | Rename one room |
| Cleaning history | `info/get_clean_time_line` | Snapshot before and after a short clean |
| Clean settings the app remembers | `clean/current_clean_task/get` | Start a clean from the Narwal app with unusual settings |

### Step 1: read side, iPhone only (Feature lab)

Settings → Diagnostics → **Feature lab**. It sends only read-only queries
and shows every field the robot reports.

1. Take a snapshot and label it ("baseline").
2. In the Narwal app, change **one** thing (volume 5 → 6). Write down what you did.
3. Swipe the Narwal app closed. The robot serves one app at a time per phone.
4. Take another snapshot ("volume 6"), then **Compare** → **Show differences**.
5. Tap the share button and paste the text into a chat with Claude.

A good diff looks like `config/get  3.2: 5 → 6`. Repeat once more with a
different value (6 → 3) to confirm. Two clean diffs pin a setting down.

If a diff shows nothing, the setting is either cloud-only or sits under a
query the lab doesn't send yet. You can type extra query topics in the lab.

### Step 2: write side

Reading a setting isn't the same as changing it. For most settings the
`…/set` command is expected to take the same message `…/get` returns. That
will be tested one harmless setting at a time (volume first), with the
result confirmed in the Narwal app before anything else is attempted.

### Optional: exact capture of the Narwal app (needs any PC with USB, no Mac)

If a write command doesn't follow the get/set pattern, the Narwal app's own
bytes settle it. `pymobiledevice3` records an iPhone's traffic over USB from
**Windows or Linux**:

1. On Windows, install Python 3 and the Apple Devices app (for the USB driver).
2. `pip install pymobiledevice3`
3. Plug in the iPhone, unlock it, tap **Trust**.
4. `pymobiledevice3 pcap --out narwal.pcap` (as administrator / root). Then do one
   action in the Narwal app and press Ctrl-C.
5. Share `narwal.pcap`. Everything to and from port 9002 can be decoded with
   the sytchi fork's `tools/decode_ws_pcap.py`.

If pcap refuses to start, enable Developer Mode with
`pymobiledevice3 amfi enable-developer-mode`, which needs a restart of the iPhone.

## Larger ideas

- **Home hub for closed-app notifications.** A tiny always-on service (it could reuse
  NarwalKit on a Mac mini, or a Python port on a Pi) that watches the robot and
  pushes alerts through self-hosted ntfy. Still no cloud.
- **"Clean when docked" queue.** Room cleans only start from the dock. The app could
  send the robot home, wait for it to dock, then start the queued clean
  instead of showing an error.
- **Zone cleaning check on the Z10 Ultra.** The shape was validated on a Flow; do one small zone near the dock first.
- **Verify the running task.** After starting a clean, read
  `clean/current_clean_task/get` and confirm that the robot's room list matches
  the one sent.
- **Home screen widget and Siri Shortcuts** for routines (App Intents).
