import base64
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from check_appcast import validate, SPARKLE


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.feed = Path(self.directory.name) / "appcast.xml"
        self.archive = Path(self.directory.name) / "fxclip.dmg"
        self.archive.write_bytes(b"update archive")
        self.item = ET.Element("item")
        ET.SubElement(self.item, SPARKLE + "version").text = "20"
        ET.SubElement(self.item, SPARKLE + "shortVersionString").text = "0.4.0"
        self.enclosure = ET.SubElement(self.item, "enclosure", {
            "url": "https://github.com/c0mm0n/fxclip/releases/download/v0.4.0/fxclip.dmg",
            "length": str(self.archive.stat().st_size),
            SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
        })

    def write_feed(self, signed=True):
        root = ET.Element("rss")
        ET.SubElement(root, "channel").append(self.item)
        footer = b"<!-- sparkle-signatures:\nedSignature: fixture\n-->" if signed else b""
        self.feed.write_bytes(ET.tostring(root) + footer)

    def test_matching_metadata(self):
        self.write_feed()
        validate(self.feed, self.archive, "0.4.0")

    def test_mutable_latest_download_is_rejected(self):
        self.enclosure.set("url", "https://github.com/c0mm0n/fxclip/releases/latest/download/fxclip.dmg")
        self.write_feed()
        with self.assertRaises(ValueError): validate(self.feed, self.archive, "0.4.0")

    def test_wrong_archive_length_is_rejected(self):
        self.write_feed()
        self.archive.write_bytes(b"different archive")
        with self.assertRaises(ValueError): validate(self.feed, self.archive, "0.4.0")

    def test_missing_archive_signature_is_rejected(self):
        self.enclosure.attrib.pop(SPARKLE + "edSignature")
        self.write_feed()
        with self.assertRaises(ValueError): validate(self.feed, self.archive, "0.4.0")

    def test_unsigned_feed_is_rejected(self):
        self.write_feed(signed=False)
        with self.assertRaises(ValueError): validate(self.feed, self.archive, "0.4.0")

    def test_wrong_version_is_rejected(self):
        self.write_feed()
        with self.assertRaises(ValueError): validate(self.feed, self.archive, "0.4.1")
