"""Validate the feed's release URL, length, signature presence and version before upload."""
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def validate(feed, archive, version):
    data = Path(feed).read_bytes()
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The stable release feed must contain exactly one complete update")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Missing update download")
    expected = f"https://github.com/c0mm0n/fxclip/releases/download/v{version}/fxclip.dmg"
    if enclosure.get("url") != expected:
        raise ValueError("Update must point at this version's immutable release URL")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Update size does not match the release DMG")
    signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
    if len(signature) != 64:
        raise ValueError("Missing Ed25519 update signature")
    if item.findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("Feed version does not match the release")
    build = item.findtext(SPARKLE + "version", "")
    if not build.isdecimal() or int(build) < 1:
        raise ValueError("Missing numeric build number")
    if b"<!-- sparkle-signatures:\n" not in data:
        raise ValueError("Missing signed feed")


if __name__ == "__main__":
    validate(*sys.argv[1:])
    print("Mac appcast metadata matches the release DMG")
