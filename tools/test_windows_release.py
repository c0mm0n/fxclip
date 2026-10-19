import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from check_windows_release import validate

class WindowsReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.asset = {'Type':'Full','Version':'0.5.0','FileName':'fxclip-0.5.0-full.nupkg','Size':7,'SHA256':hashlib.sha256(b'package').hexdigest()}
        (self.root/self.asset['FileName']).write_bytes(b'package')
        for name in ('fxclip-windows-x64.zip','fxclip-windows-setup.exe'): (self.root/name).write_bytes(b'x')
        self.feed()
    def feed(self):
        (self.root/'releases.win.json').write_text(json.dumps({'Assets':[self.asset]}))
    def test_complete_release(self): validate(self.root,'v0.5.0')
    def test_corrupt_package(self):
        (self.root/self.asset['FileName']).write_bytes(b'changed')
        with self.assertRaises(ValueError): validate(self.root,'v0.5.0')
    def test_wrong_version(self):
        with self.assertRaises(ValueError): validate(self.root,'v0.4.0')
    def test_path_escape(self):
        self.asset['FileName']='../fxclip-full.nupkg'; self.feed()
        with self.assertRaises(ValueError): validate(self.root,'v0.5.0')
    def test_incomplete_assets(self):
        (self.root/'fxclip-windows-setup.exe').unlink()
        with self.assertRaises(FileNotFoundError): validate(self.root,'v0.5.0')
