"""Feature lab from a computer on the robot's network.

Snapshots what the robot reports for read-only queries, and diffs two
snapshots: change ONE setting in the Narwal app between them and the diff
shows where it lives. Only query topics are sent; the topic that returns the
Wi-Fi password is never sent.

    pip install websockets
    python3 tools/narwal_lab.py snapshot baseline --host 192.168.68.53 --device-id <id>
    # change one setting in the Narwal app
    python3 tools/narwal_lab.py snapshot volume6 --host 192.168.68.53 --device-id <id>
    python3 tools/narwal_lab.py diff baseline volume6

The device ID is shown in Narwal Local under Settings. Snapshots are saved
in tools/lab_snapshots/ (git-ignored: they describe your home).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
from pathlib import Path

import websockets

Z10_ULTRA = "DrzDKQ0MU8"
SNAP_DIR = Path(__file__).parent / "lab_snapshots"

PROBE_TOPICS = [
    "config/get",
    "schedule/clean_schedule/get",
    "map/get_map",
    "clean/current_clean_task/get",
    "info/get_clean_time_line",
    "common/get_feature_list",
    "common/get_device_info",
    "status/get_device_base_status",
    "consumable/get_consumable_info",
    "config/key_mapping/get",
    "info/battery_info",
]
BLOCKED = {"developer/get_robot_info"}  # answers with the Wi-Fi password


def is_safe_query(topic: str) -> bool:
    last = topic.rsplit("/", 1)[-1]
    return topic not in BLOCKED and ("get" in last or last.endswith("info"))


# --- protobuf, schema-less ---------------------------------------------------

def varint(v: int) -> bytes:
    out = bytearray()
    while v > 0x7F:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def read_varint(b: bytes, i: int) -> tuple[int, int]:
    shift = value = 0
    while True:
        if i >= len(b):
            raise ValueError("truncated")
        byte = b[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def parse(b: bytes) -> list[tuple[int, int, object]]:
    fields, i = [], 0
    while i < len(b):
        key, i = read_varint(b, i)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError("field 0")
        if wire == 0:
            value, i = read_varint(b, i)
        elif wire == 1:
            value, i = b[i:i + 8], i + 8
        elif wire == 2:
            length, i = read_varint(b, i)
            if i + length > len(b):
                raise ValueError("truncated")
            value, i = b[i:i + length], i + length
        elif wire == 5:
            value, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {wire}")
        fields.append((number, wire, value))
    return fields


def flatten(b: bytes, prefix: str = "", depth: int = 0) -> dict[str, str]:
    """Same paths and value formats as the iPhone app's lab (Research.swift)."""
    fields = parse(b)
    counts: dict[int, int] = {}
    for number, _, _ in fields:
        counts[number] = counts.get(number, 0) + 1
    seen: dict[int, int] = {}
    out: dict[str, str] = {}
    for number, wire, value in fields:
        index = seen.get(number, 0)
        seen[number] = index + 1
        path = f"{prefix}.{number}" if prefix else str(number)
        if counts[number] > 1:
            path += f"[{index}]"
        if wire == 0:
            v = value if value < 2**63 else value - 2**64
            out[path] = str(v)
        elif wire == 5:
            f = struct.unpack("<f", value)[0]
            out[path] = f"{f}f" if f == f and abs(f) < 1e9 and (f == 0 or abs(f) > 1e-6) else "0x" + value[::-1].hex()
        elif wire == 1:
            out[path] = f"{struct.unpack('<d', value)[0]}d"
        else:
            out.update(leaf_bytes(value, path, depth))
    return out


def leaf_bytes(b: bytes, path: str, depth: int) -> dict[str, str]:
    if not b:
        return {path: "{}"}
    try:
        text = b.decode("utf-8")
        if len(b) >= 2 and all(c >= " " and c != "\x7f" or c == "\n" for c in text):
            return {path: json.dumps(text, ensure_ascii=False)}
    except UnicodeDecodeError:
        pass
    if depth < 12:
        try:
            nested = parse(b)
            if nested and all(n < 1000 for n, _, _ in nested):
                return flatten(b, path, depth + 1)
        except ValueError:
            pass
    shown = b[:64].hex()
    return {path: f"0x{shown}" + (f"… ({len(b)} bytes)" if len(b) > 64 else "")}


# --- robot I/O ---------------------------------------------------------------

def frame(topic: str, payload: bytes = b"") -> bytes:
    t = topic.encode()
    return bytes([0x01, len(t) + 2, 0x22, len(t)]) + t + payload


async def snapshot(host: str, key: str, device_id: str, topics: list[str]) -> dict:
    prefix = f"/{key}/{device_id}/"
    results: dict[str, dict] = {}
    async with websockets.connect(f"ws://{host}:9002", max_size=None) as ws:
        # Wake it and subscribe, as the app does; drain whatever comes back.
        sub = b"".join(
            varint(1 << 3 | 2) + varint(len(inner)) + inner
            for inner in (
                varint(1 << 3 | 2) + varint(len(t)) + t.encode() + varint(2 << 3) + varint(600)
                for t in ["status/robot_base_status", "status/working_status", "map/display_map"]
            )
        )
        await ws.send(frame(prefix + "common/notify_app_event", varint(1 << 3) + varint(1)))
        await ws.send(frame(prefix + "common/active_robot_publish", sub))
        await drain(ws, 3.0)
        for topic in topics:
            if not is_safe_query(topic):
                results[topic] = {"outcome": "not sent: not a read-only query", "fields": {}}
                continue
            await ws.send(frame(prefix + topic))
            payload = await first_response(ws, 15.0 if topic == "map/get_map" else 8.0)
            if payload is None:
                results[topic] = {"outcome": "no answer", "fields": {}}
            else:
                try:
                    fields = flatten(payload)
                except ValueError:
                    fields = {"raw": "0x" + payload.hex()}
                results[topic] = {"outcome": f"answered, {len(payload)} bytes", "fields": fields}
            print(f"{topic:34} {results[topic]['outcome']}", file=sys.stderr)
    return {"taken": time.strftime("%Y-%m-%d %H:%M:%S"), "results": results}


async def drain(ws, seconds: float) -> None:
    end = time.monotonic() + seconds
    while (left := end - time.monotonic()) > 0:
        try:
            await asyncio.wait_for(ws.recv(), left)
        except asyncio.TimeoutError:
            return


async def first_response(ws, timeout: float) -> bytes | None:
    """The next command response (0x2a frame); broadcasts are skipped."""
    end = time.monotonic() + timeout
    while (left := end - time.monotonic()) > 0:
        try:
            data = await asyncio.wait_for(ws.recv(), left)
        except asyncio.TimeoutError:
            return None
        if isinstance(data, bytes) and len(data) >= 4 and data[2] == 0x2A:
            return data[4 + data[3]:]
    return None


def diff(a: dict, b: dict) -> list[str]:
    lines = []
    for topic in sorted(set(a["results"]) | set(b["results"])):
        before = a["results"].get(topic, {}).get("fields", {})
        after = b["results"].get(topic, {}).get("fields", {})
        changed = [
            f"  {path}: {before.get(path, '∅')} → {after.get(path, '∅')}"
            for path in sorted(set(before) | set(after), key=path_key)
            if before.get(path) != after.get(path)
        ]
        if changed:
            lines.append(f"## {topic}")
            lines += changed
    return lines


def path_key(path: str) -> list[int]:
    return [int(p) for p in path.replace("[", ".").replace("]", "").split(".") if p.isdigit()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("name")
    snap.add_argument("--host", required=True)
    snap.add_argument("--device-id", required=True)
    snap.add_argument("--key", default=Z10_ULTRA)
    snap.add_argument("--topic", action="append", default=[], help="extra read-only topic")
    d = sub.add_parser("diff")
    d.add_argument("before")
    d.add_argument("after")
    args = parser.parse_args()

    SNAP_DIR.mkdir(exist_ok=True)
    if args.command == "snapshot":
        result = asyncio.run(snapshot(args.host, args.key, args.device_id, PROBE_TOPICS + args.topic))
        path = SNAP_DIR / f"{args.name}.json"
        path.write_text(json.dumps(result, indent=1, ensure_ascii=False))
        print(f"saved {path}")
    else:
        a = json.loads((SNAP_DIR / f"{args.before}.json").read_text())
        b = json.loads((SNAP_DIR / f"{args.after}.json").read_text())
        print("\n".join(diff(a, b)) or "No differences.")


if __name__ == "__main__":
    main()
