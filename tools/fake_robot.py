"""A pretend Narwal robot for trying the app without the real vacuum.

Speaks the local protocol on ws://0.0.0.0:9002: answers commands, serves a
small three-room map, broadcasts status while subscribed, and drives a
robot around during a clean.

    pip install websockets
    python3 tools/fake_robot.py [--port 9002] [--sleepy]
    # then enter your Mac's IP address in the app (Simulator: 127.0.0.1)

--sleepy starts the robot asleep, like a docked robot: it ignores every
command until a wake-up (notify_app_event or active_robot_publish) and then
takes a couple of seconds to come round.

--needs-device-id ignores commands that don't carry the robot's device id,
but broadcasts status anyway, as if the Narwal app had just woken it.

Every frame received is printed, which makes it a handy debugging aid.
"""

from __future__ import annotations

import argparse
import asyncio
import math
import struct
import time
import zlib

import websockets

PRODUCT_KEY = "DrzDKQ0MU8"
DEVICE_ID = "fakerobot01"
MAP_ID = 1742


def varint(v: int) -> bytes:
    out = bytearray()
    while v > 0x7F:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def f_varint(n: int, v: int) -> bytes:
    return varint(n << 3) + varint(v)


def f_bytes(n: int, b: bytes) -> bytes:
    return varint(n << 3 | 2) + varint(len(b)) + b


def f_float(n: int, v: float) -> bytes:
    return varint(n << 3 | 5) + struct.pack("<f", v)


def frame(kind: int, topic: str, payload: bytes) -> bytes:
    t = topic.encode()
    return bytes([0x01, len(t) + 2, kind, len(t)]) + t + payload


def response(payload: bytes) -> bytes:
    return frame(0x2A, "", payload)


def broadcast(short: str, payload: bytes) -> bytes:
    return frame(0x22, f"/{PRODUCT_KEY}/{DEVICE_ID}/{short}", payload)


# 60x40 grid: three rooms side by side with walls, row 0 at the bottom.
W, H = 60, 40
ROOMS = [(1, 4, "", 0, 20), (2, 3, "", 20, 40), (3, 5, "Ensuite", 40, 60)]


def map_payload() -> bytes:
    pixels = []
    for y in range(H):
        for x in range(W):
            if y in (0, H - 1) or x in (0, W - 1):
                pixels.append(0x28)
                continue
            for rid, _, _, x0, x1 in ROOMS:
                if x0 <= x < x1:
                    wall = x in (x0, x1 - 1) and not (15 <= y <= 22)
                    pixels.append(rid << 8 | (0x10 if wall else 0))
                    break
    grid = zlib.compress(f_bytes(1, b"".join(varint(p) for p in pixels)))
    rooms = b"".join(
        f_bytes(12, f_varint(1, rid) + f_varint(2, rtype) + (f_bytes(3, name.encode()) if name else b"")
                + f_varint(4, 1))
        for rid, rtype, name, _, _ in ROOMS
    )
    body = (
        f_varint(1, MAP_ID) + f_varint(3, 60) + f_varint(4, W) + f_varint(5, H)
        + f_bytes(6, f_varint(1, 0) + f_varint(3, 0) + f_varint(4, 60))
        + f_bytes(8, f_bytes(1, f_float(1, 5.0) + f_float(2, 5.0)))
        + rooms + f_bytes(17, grid)
        # 9: a no-go zone (ForbiddenArea, float polygon), 50: a virtual wall
        + f_bytes(9, b"".join(f_bytes(1, f_float(1, x) + f_float(2, y))
                              for x, y in [(25, 10), (35, 10), (35, 18), (25, 18)])
                  + f_varint(2, 3) + f_varint(3, 1))
        + f_bytes(50, f_varint(1, 2) + f_bytes(2, f_float(1, 45) + f_float(2, 25))
                  + f_bytes(3, f_float(1, 45) + f_float(2, 35)))
        # 26: a carpet (Grid polygon), 32.1: a sofa, 11: a doorway (Grid points)
        + f_bytes(26, f_varint(1, 1) + b"".join(f_bytes(2, f_varint(1, x) + f_varint(2, y))
                                                  for x, y in [(4, 4), (14, 4), (14, 12), (4, 12)])
                  + f_varint(12, 1))
        + f_bytes(32, f_bytes(1, f_varint(1, 5) + f_varint(2, 14)
                              + f_bytes(3, f_bytes(1, f_float(1, 30) + f_float(2, 30)) + f_float(2, 12) + f_float(3, 4))
                              + f_float(4, 15)))
        + f_bytes(11, f_bytes(1, varint(1) + varint(2)) + f_bytes(2, f_varint(1, 20) + f_varint(2, 15))
                  + f_bytes(2, f_varint(1, 20) + f_varint(2, 22)))
    )
    return f_varint(1, 1) + f_bytes(2, body)


class Robot:
    def __init__(self) -> None:
        self.status = 14  # charged on dock
        self.paused = False
        self.returning = False
        self.battery = 100.0
        self.subscribed_until = 0.0
        self.rooms: list[int] = []
        self.started = 0.0
        self.x, self.y, self.heading = 5.0, 5.0, 0.0

    @property
    def cleaning(self) -> bool:
        return self.status == 4

    def base_status(self) -> bytes:
        docked = not self.cleaning and not self.returning
        task = f_varint(1, self.status) + f_varint(2, int(self.paused)) + f_varint(7, int(self.returning))
        task += f_varint(10, 1 if docked else 2)
        return (f_float(2, self.battery) + f_bytes(3, task) + f_varint(11, 2 if docked else 1)
                + f_varint(23, 1) + f_varint(24, 1) + f_varint(26, 2) + f_varint(29, 2))

    def handle(self, short: str, payload: bytes) -> bytes | None:
        if short == "status/app_status_heartbeat":
            return None
        if short == "common/active_robot_publish":
            self.subscribed_until = time.time() + 600
        elif short == "common/get_device_info":
            return response(f_bytes(1, PRODUCT_KEY.encode()) + f_bytes(2, DEVICE_ID.encode())
                            + f_bytes(3, b"v01.00.00.00-fake"))
        elif short == "status/get_device_base_status":
            return response(f_varint(1, 1) + f_bytes(2, self.base_status()))
        elif short == "map/get_map":
            return response(map_payload())
        elif short == "info/get_clean_time_line":
            # GetCleanTimeLine.Response {1 result, 2 TimeLineStatus {1 RobotEventNode...}}
            start = int(time.time() * 1000) - 3_600_000
            clean = (f_varint(1, start) + f_varint(2, 4) + f_bytes(3, f_bytes(2, f_varint(2, 2) + f_varint(4, 4)))
                     + f_varint(5, 1) + f_varint(7, 1) + f_varint(8, 1))
            dust = f_varint(1, start + 1_800_000) + f_varint(2, 9) + f_varint(7, 1) + f_varint(8, 2)
            return response(f_varint(1, 1) + f_bytes(2, f_bytes(1, clean) + f_bytes(1, dust)))
        elif short == "consumable/get_consumable_info":
            return response(f_bytes(1, f_bytes(1, bytes([4])) + f_bytes(2, bytes([3]))))
        elif short == "clean/start_clean":
            if self.cleaning or self.returning:
                return response(f_varint(1, 2))
            self.status, self.paused, self.started = 4, False, time.time()
        elif short == "task/pause":
            self.paused = True
        elif short == "task/resume":
            self.paused = False
        elif short in ("task/force_end", "supply/recall"):
            if self.cleaning:
                self.status, self.returning, self.paused = 1, True, False
        return response(f_varint(1, 1))

    def tick(self) -> None:
        if self.cleaning and not self.paused:
            t = time.time() - self.started
            self.heading = t * 0.3
            self.x = 30 + 22 * math.cos(self.heading)
            self.y = 20 + 14 * math.sin(self.heading * 1.7)
            self.battery = max(5.0, self.battery - 0.05)
            if t > 120:
                self.status, self.returning = 19, True
        elif self.returning:
            self.x += (5 - self.x) * 0.3
            self.y += (5 - self.y) * 0.3
            if abs(self.x - 5) < 0.5:
                self.status, self.returning, self.x, self.y = 10, False, 5.0, 5.0
        elif self.battery < 100:
            self.battery = min(100.0, self.battery + 0.5)


SLEEPY = False
NEEDS_DEVICE_ID = False
WAKE_DELAY = 2.0
# Like a Z10 Ultra: a command addressed with another model's product key gets
# the client dropped, and reconnection is refused for ~10 s afterwards.
REFUSE_FOR = 10.0
refuse_until = 0.0


async def serve(ws) -> None:  # type: ignore[no-untyped-def]
    global refuse_until
    if time.time() < refuse_until:
        print("refusing connection (recently dropped a client)", flush=True)
        await ws.close()
        return
    robot = Robot()
    if NEEDS_DEVICE_ID:
        robot.subscribed_until = float("inf")  # someone else subscribed it
    awake_at = float("inf") if SLEEPY else 0.0
    print("app connected", flush=True)

    async def broadcasts() -> None:
        while True:
            await asyncio.sleep(1.5)
            robot.tick()
            if time.time() > robot.subscribed_until:
                continue
            await ws.send(broadcast("status/robot_base_status", robot.base_status()))
            if robot.cleaning or robot.returning:
                t = time.time() - robot.started
                await ws.send(broadcast("status/working_status",
                                        f_float(1, min(t / 120, 1)) + f_float(2, t / 10)
                                        + f_varint(3, int(t)) + f_varint(4, max(0, 120 - int(t)))
                                        + f_bytes(6, f_varint(1, 1 + int(robot.x // 20)))))
                pose = f_bytes(1, f_bytes(1, f_float(1, robot.x) + f_float(2, robot.y)) + f_float(2, robot.heading))
                await ws.send(broadcast("map/display_map", pose + f_varint(10, int(time.time() * 1000))))

    task = asyncio.create_task(broadcasts())
    try:
        async for data in ws:
            if not isinstance(data, bytes) or len(data) < 4:
                continue
            topic = data[4:4 + data[3]].decode()
            payload = data[4 + data[3]:]
            short = "/".join(topic.split("/")[3:])
            print(f"<- {topic:50} {payload.hex()}", flush=True)
            # Like a Z10 Ultra: another model's product key gets the client
            # dropped (the device id may be empty).
            if topic.split("/")[1:2] != [PRODUCT_KEY]:
                print("wrong product key: dropping client", flush=True)
                refuse_until = time.time() + REFUSE_FOR
                await ws.close()
                return
            if NEEDS_DEVICE_ID and topic.split("/")[2:3] != [DEVICE_ID]:
                continue
            if time.time() < awake_at:
                if short in ("common/notify_app_event", "common/active_robot_publish") and awake_at == float("inf"):
                    awake_at = time.time() + WAKE_DELAY
                    print("   (waking up)", flush=True)
                continue
            reply = robot.handle(short, payload)
            if reply is not None:
                await ws.send(reply)
    finally:
        task.cancel()
        print("app disconnected")


async def main() -> None:
    global SLEEPY, NEEDS_DEVICE_ID
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9002)
    parser.add_argument("--sleepy", action="store_true")
    parser.add_argument("--needs-device-id", action="store_true")
    args = parser.parse_args()
    SLEEPY = args.sleepy
    NEEDS_DEVICE_ID = args.needs_device_id
    async with websockets.serve(serve, "0.0.0.0", args.port, max_size=None):
        print(f"fake Narwal robot on ws://0.0.0.0:{args.port}{' (sleepy)' if SLEEPY else ''}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
