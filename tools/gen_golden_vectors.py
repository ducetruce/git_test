"""Emit byte-exact payloads from the reference Python client as Swift test fixtures.

The reference (github.com/sjmotew/NarwalIntegration, MIT) is verified against
real robots, so NarwalKit's encoders are tested for byte equality with it.

Usage:
    python3 tools/gen_golden_vectors.py <path-to-NarwalIntegration-checkout> \
        > NarwalKit/Tests/NarwalKitTests/GoldenVectors.swift
"""

from __future__ import annotations

import sys

sys.path.insert(0, sys.argv[1])

from narwal_client.client import NarwalClient, RoomCleanSettings  # noqa: E402
from narwal_client.const import (  # noqa: E402
    CleaningRoute,
    FanLevel,
    MopHumidity,
    MopStrengthLevel,
    WorkMode,
)
from narwal_client.protocol import build_frame  # noqa: E402

client = NarwalClient("127.0.0.1", device_id="DEV123", topic_prefix="/DrzDKQ0MU8")

vectors: list[tuple[str, bytes]] = [
    ("frameYell", build_frame("/DrzDKQ0MU8/DEV123/common/yell", b"")),
    ("frameSetFan", build_frame("/DrzDKQ0MU8/DEV123/clean/set_fan_level", b"\x08\x03")),
    ("subscription600", client._build_topic_subscription(600)),
    ("notifyAppEvent", client._encode_varint_field(1, 1)),
    ("activeRobotDuration600", client._encode_varint_field(1, 600)),
    (
        "startCleanDefaultsTwoRooms",
        client._build_start_clean_payload([3, 5], 7),
    ),
    (
        "startCleanDefaultsOneRoom",
        client._build_start_clean_payload([4], 7),
    ),
    (
        "startCleanVacuumStrongTwoPassesMeticulous",
        client._build_start_clean_payload(
            [1, 2, 9],
            300,
            work_mode=WorkMode.VACUUM,
            fan=FanLevel.STRONG,
            water=MopHumidity.WET,
            mop_strength=MopStrengthLevel.HIGH,
            passes=2,
            route=CleaningRoute.METICULOUS,
        ),
    ),
    (
        "startCleanMixedPerRoom",
        client._build_start_clean_payload(
            [2, 6],
            7,
            room_settings={
                2: RoomCleanSettings(work_mode=WorkMode.VACUUM_THEN_MOP, fan=FanLevel.SUPER,
                                     water=MopHumidity.DRY, passes=3),
                6: RoomCleanSettings(work_mode=WorkMode.MOP, water=MopHumidity.WET),
            },
        ),
    ),
]

# --- Parse fixtures: built here, interpreted by the reference parser ------

import struct  # noqa: E402
import zlib  # noqa: E402

from narwal_client.models import MapData, MapDisplayData, NarwalState  # noqa: E402
from narwal_client.map_renderer import _decode_packed_varints, decompress_map  # noqa: E402


def varint(v: int) -> bytes:
    return NarwalClient._encode_varint(v)


def f_varint(n: int, v: int) -> bytes:
    return NarwalClient._encode_varint_field(n, v)


def f_bytes(n: int, b: bytes) -> bytes:
    return NarwalClient._encode_bytes_field(n, b)


def f_float(n: int, v: float) -> bytes:
    return varint(n << 3 | 5) + struct.pack("<f", v)


# 4x3 grid, row 0 at the bottom: room 1 floor/wall, room 2 floor, unassigned.
grid = [0x100, 0x100, 0x200, 0x200,
        0x110, 0x100, 0x200, 0x20,
        0, 0x28, 0x210, 0]
packed = b"".join(varint(v) for v in grid)
compressed = zlib.compress(f_bytes(1, packed))
room1 = f_varint(1, 1) + f_varint(2, 4) + f_varint(4, 1)
room2 = f_varint(1, 2) + f_varint(2, 5) + f_bytes(3, "Ensuite".encode()) + f_varint(4, 1)
room3 = f_varint(1, 3) + f_varint(2, 5) + f_varint(4, 1) + f_varint(8, 2)
map_payload = (
    f_varint(1, 1742) + f_varint(3, 60) + f_varint(4, 4) + f_varint(5, 3)
    + f_bytes(6, f_varint(1, 10) + f_varint(3, 20) + f_varint(4, 60))
    + f_bytes(8, f_bytes(1, f_float(1, 21.5) + f_float(2, 11.0)) + f_float(2, 1.5))
    + f_bytes(12, room1) + f_bytes(12, room2) + f_bytes(12, room3)
    + f_bytes(17, compressed)
)
map_response = f_varint(1, 1) + f_bytes(2, map_payload)
decoded_map, _ = __import__("blackboxprotobuf").decode_message(map_response)
ref_map = MapData.from_response(decoded_map)
assert ref_map.map_id == 1742 and (ref_map.width, ref_map.height) == (4, 3)
assert [r.display_name for r in ref_map.rooms] == ["Kitchen", "Ensuite", "Bathroom 2"]
assert (ref_map.origin_x, ref_map.origin_y) == (20, 10)
assert (ref_map.dock_x, ref_map.dock_y) == (1.5, 1.0), (ref_map.dock_x, ref_map.dock_y)
assert _decode_packed_varints(decompress_map(ref_map.compressed_map)) == grid

# robot_base_status while cleaning off the dock on newer firmware, with a fault.
base_status = (
    f_bytes(1, f_varint(1, 2103) + f_varint(2, 2) + f_bytes(3, b"wheel"))
    + f_float(2, 83.0)
    + f_bytes(3, f_varint(1, 2) + f_varint(4, 3))
    + f_varint(11, 1) + f_varint(23, 3) + f_varint(24, 1) + f_varint(26, 3) + f_varint(29, 2)
    + f_varint(47, 2)
)
state = NarwalState()
decoded_bs, _ = __import__("blackboxprotobuf").decode_message(base_status)
state.update_from_base_status(decoded_bs)
assert state.battery_level == 83
assert int(state.working_status) == 3, state.working_status  # promoted to CLEANING_V2
assert state.error_codes == [2103]
assert state.clean_water_tank_state == 3 and state.sewage_tank_state == 1
assert not state.is_docked

# Docked and charging on older firmware.
base_status_docked = f_float(2, 100.0) + f_bytes(3, f_varint(1, 10) + f_varint(10, 1)) + f_varint(11, 2)
state2 = NarwalState()
decoded_bs2, _ = __import__("blackboxprotobuf").decode_message(base_status_docked)
state2.update_from_base_status(decoded_bs2)
assert state2.battery_level == 100 and state2.is_docked

# display_map pose.
display_map = f_bytes(1, f_bytes(1, f_float(1, 123.25) + f_float(2, -45.5)) + f_float(2, 1.5707964)) \
    + f_varint(10, 1760000000000)
decoded_dm, _ = __import__("blackboxprotobuf").decode_message(display_map)
pose = MapDisplayData.from_broadcast(decoded_dm)
assert (pose.robot_x, pose.robot_y, pose.timestamp) == (123.25, -45.5, 1760000000000)

# working_status: 42% progress as a 0..1 float, 12.5 m2, 600 s, current room 2.
working = f_float(1, 0.42) + f_float(2, 12.5) + f_varint(3, 600) + f_varint(4, 900) + f_bytes(6, f_varint(1, 2))
state3 = NarwalState()
decoded_ws, _ = __import__("blackboxprotobuf").decode_message(working)
state3.update_from_working_status(decoded_ws)
assert state3.task_progress_percent == 42 and state3.cleaning_time == 600, (state3.task_progress_percent, state3.cleaning_time)
assert state3.current_room_id == 2

# consumable alerts: packed maintain [4, 6, 8, 10], replace [3, 20] (AX12 capture).
consumables = f_bytes(1, f_bytes(1, bytes([4, 6, 8, 10])) + f_bytes(2, bytes([3, 20])))
state4 = NarwalState()
decoded_c, _ = __import__("blackboxprotobuf").decode_message(consumables)
state4.update_from_consumable_info(decoded_c)
assert state4.maintain_items == [4, 6, 8, 10] and state4.replace_items == [3, 20]

vectors += [
    ("mapResponse", map_response),
    ("baseStatusCleaningOffDockWithFault", base_status),
    ("baseStatusDockedCharged", base_status_docked),
    ("displayMapPose", display_map),
    ("workingStatus", working),
    ("consumableInfo", consumables),
]

print("// Generated by tools/gen_golden_vectors.py from the reference Python client.")
print("// Do not edit by hand; regenerate instead.")
print()
print("enum GoldenVectors {")
for name, data in vectors:
    print(f'    static let {name} = "{data.hex()}"')
print("}")
