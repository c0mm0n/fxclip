"""Build-time only: verify and retain the complete upstream distribution."""
import hashlib
import io
from pathlib import Path
import shutil
import tarfile
import urllib.request

REVISION = "990860a01ca865774b0e77b5de9af76b54947900"
SHA256 = "946fadb5a0c68e7b0ce6064e66563cfa6f25580b9cbd84f02ead7f1c41caf443"
url = f"https://codeload.github.com/dylanpdx/vxReddit/tar.gz/{REVISION}"
with urllib.request.urlopen(url, timeout=60) as response:
    archive = response.read(4 * 1024 * 1024 + 1)
assert len(archive) <= 4 * 1024 * 1024
assert hashlib.sha256(archive).hexdigest() == SHA256, "Upstream checksum mismatch"
with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
    source.extractall("/tmp/source", filter="data")
root = Path("/tmp/source") / f"vxReddit-{REVISION}"
assert "Version 2, December 2004" in (root / "LICENSE.txt").read_text()
shutil.copytree(root, "/opt/vxreddit")
Path("/opt/vxreddit/REVISION").write_text(REVISION + "\n")
Path("/opt/vxreddit/ARCHIVE_SHA256").write_text(SHA256 + "\n")
