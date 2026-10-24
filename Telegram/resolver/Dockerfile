# syntax=docker/dockerfile:1
FROM python:3.14-slim@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8 AS build
WORKDIR /opt/facebed
COPY Telegram/resolver/requirements.txt /tmp/requirements.txt
COPY Telegram/resolver/requirements.lock /tmp/requirements.lock
# No GitHub credentials or mutable branch/tag: verify the complete source bundle.
RUN python - <<'PY'
import hashlib
import io
import tarfile
import urllib.request
revision = 'ccc612c6d99bdd126b3a6f5ea3fe9fb88ee04e72'
url = f'https://codeload.github.com/facebed/facebed/tar.gz/{revision}'
with urllib.request.urlopen(url, timeout=60) as response:
    archive = response.read(8 * 1024 * 1024)
assert hashlib.sha256(archive).hexdigest() == 'c72514385f302a298c6bcc42e487df165e2bb8e45dcb38435e8c5073978e2e86', 'Source checksum mismatch'
with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as source:
    source.extractall('/tmp/upstream', filter='data')
from pathlib import Path
import shutil
root = Path('/tmp/upstream') / f'facebed-{revision}'
assert (root / 'requirements.txt').read_bytes() == Path('/tmp/requirements.txt').read_bytes(), 'Upstream requirements changed'
for name in ('facebed.py', 'assets', 'README.md', 'requirements.txt'):
    src = root / name
    if src.is_dir():
        shutil.copytree(src, name)
    else:
        shutil.copyfile(src, name)
Path('REVISION').write_text(revision + '\n')
PY
RUN python -m pip install --no-cache-dir --target /opt/python -r requirements.txt -c /tmp/requirements.lock \
    && python -m pip freeze --path /opt/python > dependency-freeze.txt

FROM python:3.14-slim@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/python:/opt/facebed TMPDIR=/tmp
RUN useradd --no-log-init --uid 10002 --user-group --no-create-home --shell /usr/sbin/nologin resolver
COPY --from=build /opt/python /opt/python
COPY --from=build /opt/facebed /opt/facebed
WORKDIR /service
COPY Telegram/resolver/service.py Telegram/resolver/healthcheck.py ./
USER 10002:10002
EXPOSE 9812
HEALTHCHECK --interval=30s --timeout=4s --start-period=5s --retries=3 CMD ["python", "/service/healthcheck.py"]
CMD ["python", "/service/service.py"]
