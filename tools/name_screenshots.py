"""Renames screenshots exported by `xcresulttool export attachments` to the
names the UI test gave them, using the export's manifest.json.

    python3 tools/name_screenshots.py <export dir>
"""

import json
import sys
from pathlib import Path

folder = Path(sys.argv[1])
for test in json.loads((folder / "manifest.json").read_text()):
    for attachment in test.get("attachments", []):
        source = folder / attachment["exportedFileName"]
        name = attachment.get("suggestedHumanReadableName") or source.name
        if source.exists():
            source.rename(folder / name.replace("/", "-"))
