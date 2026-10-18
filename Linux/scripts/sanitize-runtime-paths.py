#!/usr/bin/env python3
"""Neutralize vendor build-directory strings in the statically linked Swift runtime.

Compiler prefix maps cover our sources, but cannot change prebuilt runtime
assertion filenames. An equal-length replacement preserves ELF offsets and Swift
string lengths. All other home paths remain a hard failure in the workflow.
"""
import sys
from pathlib import Path

binary = Path(sys.argv[1])
prefix = b"/" + b"home/" + b"build-user/"
neutral = b"/opt/swift-src__/"
assert len(prefix) == len(neutral)
data = binary.read_bytes()
count = data.count(prefix)
if count:
    binary.write_bytes(data.replace(prefix, neutral))
print(f"Neutralized {count} Swift vendor source-path prefixes")
