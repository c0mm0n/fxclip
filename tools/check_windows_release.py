"""Ensure the Windows feed and its exact full package are published together."""
import hashlib
import json
from pathlib import Path
import sys

def validate(directory, tag):
    directory = Path(directory)
    assets = json.loads((directory / 'releases.win.json').read_text())['Assets']
    if len(assets) != 1:
        raise ValueError('Expected one full stable Windows package')
    asset = assets[0]
    if asset['Type'] != 'Full' or asset['Version'] != tag.removeprefix('v'):
        raise ValueError('Incorrect Windows release version')
    name = asset['FileName']
    if Path(name).name != name or name != f'fxclip-{asset["Version"]}-full.nupkg':
        raise ValueError('Invalid Windows package filename')
    data = (directory / name).read_bytes()
    if len(data) != asset['Size'] or hashlib.sha256(data).hexdigest().lower() != asset['SHA256'].lower():
        raise ValueError('Windows package digest mismatch')
    for name in ('fxclip-windows-x64.zip', 'fxclip-windows-setup.exe'):
        if not (directory / name).stat().st_size:
            raise ValueError('Empty Windows download')

if __name__ == '__main__':
    validate(*sys.argv[1:])
    print('Windows feed and downloads validated')
