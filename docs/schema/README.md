# Protocol schema (Narwal Android app 2.9.90)

Field numbers and names for the robot's protobuf messages, recovered from the
Narwal Android app's Flutter code (`libapp.so`, Dart 3.9.2) with
[blutter](https://github.com/worawit/blutter) and `tools/schema/`. They were
checked against a live Z10 Ultra's answers to read-only queries (`tools/narwal_lab.py`).

| File | Contents |
|---|---|
| `messages.txt` | 604 messages: `number name: type`. Grouped by source file; `srv/<area>/<Name>` is the request/response pair for topic `<area>/...` |
| `enums.txt` | 230 enums with their numeric values |
| `topics.txt` | Every path string in the app. Most are robot topics; `api/`, `login/`, `user/` and similar are Narwal cloud paths |

Types come from protobuf.dart's field-type codes. A bare `message` or `enum`
without a name means the extractor couldn't see the type; look it up by the
field name in the same file.

## Things the schema settles

- **`config/set` is not `config/get`.** The two number their fields
  differently: get 1–3 = set 1–3; get 4–13 = set 5–14 (set skips 4); get 14
  has no setter; get 15–44 = set 15–44; get 46–47 = set 45–46; get 49–56 =
  set 47–54. `RobotSettingKey.all` (NarwalKit) holds the mapping for every
  setting the app shows, and a unit test restates the rule. `SetConfig` is a
  `oneof`: one setting per request.
- Voice volume is `volumePercentage` (0–100). The app also has a `config/volume/set`
  topic; its payload message wasn't found.
- Do-not-disturb is `DisturbMode {1 enabled, 2 beginTime, 3 endTime}`, times in
  seconds after midnight.
- Schedules: `CleanSchedule {1 taskId, 2 CleanScheduleParam}`, where
  `CleanScheduleParam.crontab` is `Crontab {1 cron string, 2 remindingTime, 3 enabled}`.
  The Z10 Ultra didn't answer `schedule/clean_schedule/get` (empty request), and
  `clean/plan/get` returned no plans; open question.
- No-go zones are `StaticMapPayload` field 9 (`ForbiddenArea`), virtual walls are
  field 50 (`VirtualWallData`). Edits go through `map/operation`: a
  `MapOperation.Request` whose `operations` (4) are `MapOperationPayload`s
  (`forbiddenAreaOperation` = 4, `virtualWallOperation` = 13, room split = 1,
  merge = 2, rename via `roomInfoOperation` = 3).

## Regenerating for a newer app

```bash
python3 blutter.py <apk>/lib/arm64-v8a out
python3 tools/schema/pbschema.py out/asm/app_protol docs/schema/messages.txt
python3 tools/schema/pbenums.py out/objs.txt docs/schema/enums.txt
```
