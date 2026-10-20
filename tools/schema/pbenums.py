import re, sys
from collections import defaultdict
txt = open(sys.argv[1], errors="replace").read()
enums = defaultdict(dict)
for m in re.finditer(r'Obj!(\w+)@[0-9a-f]+ : \{\n  Super!ProtobufEnum : \{\n    off_8: int\((0x[0-9a-f]+)\),\n    off_10: "([^"]*)"', txt):
    enums[m.group(1)][int(m.group(2), 16)] = m.group(3)
with open(sys.argv[2], "w") as f:
    for name in sorted(enums):
        f.write(f"enum {name} {{\n" + "".join(f"  {k:>3} {v}\n" for k, v in sorted(enums[name].items())) + "}\n")
print(len(enums), "enums")
