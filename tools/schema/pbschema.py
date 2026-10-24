"""Rebuild protobuf schemas from blutter output of Dart *.pb.dart files.

Each message's static BuilderInfo _i() registers fields as:
    r0|r2 = <number>; r16|r3 = "<name>"; [r0 = <PbFieldType>]; ...; r0 = <method>()
"""
import re
import sys
from pathlib import Path

INT = re.compile(r"^\s*// 0x[0-9a-f]+: r(\d+) = (-?\d+)$")
STR = re.compile(r'^\s*// 0x[0-9a-f]+: r\d+ = "([^"]*)"$')
TARG = re.compile(r"r\d+ = <([^>]+)>$")
CLOS = re.compile(r"Closure: \(\w*\) => (\w+)\?? from Function '(create|valueOf)'")
CALL = re.compile(r"^\s*// 0x[0-9a-f]+: r0 = (\w+)\(\)$")
START = re.compile(r"static BuilderInfo _i\(\)")

PBTYPE = {  # protobuf.dart PbFieldType bits
    0x10: "bool", 0x20: "bytes", 0x40: "string", 0x80: "double", 0x100: "float",
    0x200: "enum", 0x400: "group", 0x800: "int32", 0x1000: "int64", 0x2000: "sint32",
    0x4000: "sint64", 0x8000: "uint32", 0x10000: "uint64", 0x20000: "fixed32",
    0x40000: "fixed64", 0x80000: "sfixed32", 0x100000: "sfixed64", 0x200000: "message",
    0x400000: "map",
}
METHOD = {"aOB": "bool", "aOS": "string", "aOM": "message", "aInt64": "int64", "e": "enum",
          "pc": "repeated", "pPS": "repeated string", "m": "map", "aI": "int32", "aD": "double"}


def ftype(code):
    if code is None:
        return None
    rep = "repeated " if code & 0x2 else ""
    base = [n for b, n in PBTYPE.items() if code & b]
    return rep + (base[0] if base else hex(code))


def parse(path):
    out, msg, fields = [], None, None
    lines = path.read_text(errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if START.search(line):
            msg, fields, pending = None, [], {}
        elif fields is not None:
            if line.startswith("  }"):
                if msg:
                    out.append((msg, fields))
                fields = None
            elif (m := STR.match(line)):
                s = m.group(1)
                if msg is None and "." in s or (msg is None and s[:1].isupper()):
                    msg = s
                elif "num" in pending and "name" not in pending:
                    pending["name"] = s
            elif (m := INT.match(line)):
                n = int(m.group(2))
                if "name" in pending and "code" not in pending:
                    pending["code"] = n
                elif "name" not in pending:
                    pending["num"] = n
            elif (m := CLOS.search(line)) or (m := TARG.search(line)):
                if "name" in pending or "num" in pending or True:
                    pending.setdefault("hint", m.group(1))
            elif (m := CALL.match(line)) and m.group(1) not in ("BuilderInfo",):
                if "name" in pending and "num" in pending:
                    t = ftype(pending.get("code")) or METHOD.get(m.group(1), m.group(1))
                    hint = pending.get("hint")
                    if hint and hint not in ("int", "String", "bool", "double", "Int64") and hint != msg.replace(".", "_"):
                        t = f"{t} {hint}"
                    fields.append((pending["num"], pending["name"], t))
                pending = {}
        i += 1
    return out


def main(root, outfile):
    lines = []
    for p in sorted(Path(root).rglob("*.pb.dart")):
        msgs = parse(p)
        if not msgs:
            continue
        lines.append(f"// {p.relative_to(root)}")
        for msg, fields in msgs:
            lines.append(f"message {msg} {{")
            for num, name, t in fields:
                lines.append(f"  {num:>3} {name}: {t}")
            lines.append("}")
        lines.append("")
    Path(outfile).write_text("\n".join(lines))
    print(f"{sum(1 for l in lines if l.startswith('message'))} messages")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
