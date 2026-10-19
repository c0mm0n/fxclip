#!/usr/bin/env python3
"""Choose a release for a main push, or honor an explicit version tag."""
import argparse
import json
import re
from pathlib import Path

VERSION = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")


def version(tag):
    match = VERSION.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def choose(releases, notes, ref_type, ref_name, sha):
    published = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    if ref_type == "tag":
        if version(ref_name) is None:
            raise ValueError("Expected a stable vMAJOR.MINOR.PATCH tag")
        tag = ref_name
        publish = not any(r["tag_name"] == tag for r in published)
    else:
        if ref_name != "main":
            raise ValueError("Automatic releases only run from main")
        if any(r.get("target_commitish") == sha for r in published):
            return {"publish": "false"}
        latest = max((version(r["tag_name"]) for r in published if version(r["tag_name"])), default=(0, 0, 0))
        planned = [version(tag) for tag in notes if version(tag) and version(tag) > latest]
        selected = max(planned) if planned else (latest[0], latest[1], latest[2] + 1)
        tag = "v" + ".".join(map(str, selected))
        publish = True
    return {"publish": str(publish).lower(), "tag": tag, "number": tag[1:]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--releases", type=Path, required=True)
    parser.add_argument("--ref-type", required=True)
    parser.add_argument("--ref-name", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    result = choose(json.loads(args.releases.read_text()),
                    [p.stem for p in Path("release-notes").glob("v*.md")],
                    args.ref_type, args.ref_name, args.sha)
    for key, value in result.items():
        print(f"{key}={value}")
