#!/usr/bin/env python3
"""Build the Windows ICO from existing PNGs, without image dependencies.

Run from the repository root: python3 Windows/tools/make_icon.py
ICO supports PNG-compressed entries; retain the original artwork byte for byte.
"""
from pathlib import Path
import struct

root = Path(__file__).resolve().parents[2]
source = root / "App/Assets.xcassets/AppIcon.appiconset"
sizes = [16, 32, 128, 256]
images = [(size, (source / f"icon_{size}x{size}.png").read_bytes()) for size in sizes]
offset = 6 + 16 * len(images)
header = struct.pack("<HHH", 0, 1, len(images))
entries = []
for size, data in images:
    entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
output = root / "Windows/Fxclip/Assets/fxclip.ico"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(header + b"".join(entries) + b"".join(data for _, data in images))
print("Generated Windows/Fxclip/Assets/fxclip.ico")
