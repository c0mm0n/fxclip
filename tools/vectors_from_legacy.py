#!/usr/bin/env python3
"""Builds Shared/vectors.json from the legacy fxclip binary (the behaviour oracle).

The legacy test mode prints the cleaned text, then the Telegram version, each with
the same number of lines, so the output is split in half.

Usage: tools/vectors_from_legacy.py [path-to-legacy-binary]
"""
import json
import pathlib
import subprocess
import sys

LEGACY = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path.home() / ".local/bin/fxclip")
OUT = pathlib.Path(__file__).resolve().parent.parent / "Shared/vectors.json"

INPUTS = [
    "https://x.com/jack/status/20?s=46&t=abcDEF",
    "https://twitter.com/a/status/1?ref_src=twsrc%5Etfw",
    "https://mobile.x.com/a/status/1",
    "http://X.COM/a/status/1?s=1",
    "https://x.com",
    "https://sub.x.com/a?s=1",
    "https://notx.com/a?s=1",
    "https://www.instagram.com/p/DeUHj7eM0ws/?exln=MXh5NzlwOHAxNDhtbg==",
    "https://www.instagram.com/reel/abc/?igsh=MTc4&utm_source=ig",
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc&t=42s",
    "https://youtu.be/dQw4w9WgXcQ?si=xyz",
    "https://www.youtube.com/watch?v=a&list=PL1&pp=ygU",
    "https://www.amazon.fr/dp/B0ABC/ref=sr_1_1?keywords=foo&qid=123&tag=aff-21&th=1",
    "https://www.amazon.com/gp/product/B01?linkCode=ll1&linkId=x&smid=A1",
    "https://amzn.eu/d/abc/ref=x",
    "https://example.com/?utm_source=a&utm_medium=b&id=5#frag",
    "https://example.com/?q=a%2Bb&utm_campaign=x",
    "https://github.com/foo/bar?ref=main",
    "https://example.com/page?fbclid=IwAR&gclid=xyz",
    "https://example.com/?UTM_SOURCE=a",
    "https://example.com/?FBCLID=a",
    "https://example.com/?utm%5Fsource=a&b=1",
    "https://example.com/?=x&&utm_source=a",
    "https://example.com/?utm_source=a",
    "see (https://x.com/a/status/1?s=20).",
    "[link](https://x.com/a/status/1?t=1)",
    "https://en.wikipedia.org/wiki/Foo_(bar)",
    "https://example.com/redirect?url=https://x.com/a/status/1?s=1",
    "https://www.tiktok.com/@u/video/1?_t=abc&_r=1&is_from_webapp=1",
    "https://open.spotify.com/track/1?si=abc&context=x",
    "https://www.reddit.com/r/a/comments/b/?share_id=x&context=3",
    "https://www.linkedin.com/posts/x?trk=public&lipi=abc",
    "https://www.facebook.com/x?mibextid=abc",
    "https://www.aliexpress.com/item/1.html?spm=a&sk=b&pvid=c",
    "a https://x.com/a/status/1?s=1 and https://youtu.be/x?si=1.",
    "hello world",
    "line1 https://x.com/a?s=1\nline2 https://instagram.com/p/x/?igsh=1",
    "Is it https://x.com/a?s=1?!",
    "https://example.com/a)))",
]

vectors = []
for text in INPUTS:
    out = subprocess.run([LEGACY, text], capture_output=True, text=True, check=True).stdout
    lines = out.split("\n")[:-1]  # trailing newline from print
    half = len(lines) // 2
    assert len(lines) == 2 * half, text
    vectors.append({
        "input": text,
        "clean": "\n".join(lines[:half]),
        "telegram": "\n".join(lines[half:]),
    })

OUT.write_text(json.dumps({"source": "legacy fxclip.swift test mode", "vectors": vectors}, indent=2, ensure_ascii=False) + "\n")
print(f"{len(vectors)} vectors → {OUT}")
