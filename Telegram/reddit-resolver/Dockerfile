# syntax=docker/dockerfile:1
FROM python:3.14-slim@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8 AS build
ENV PYTHONDONTWRITEBYTECODE=1
COPY Telegram/reddit-resolver/fetch_upstream.py /tmp/fetch_upstream.py
RUN python /tmp/fetch_upstream.py
COPY Telegram/reddit-resolver/requirements.lock /tmp/requirements.lock
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes \
      --target /opt/python -r /tmp/requirements.lock \
    && python -m pip freeze --path /opt/python > /opt/vxreddit/dependency-freeze.txt

FROM python:3.14-slim@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/python TMPDIR=/tmp \
    RUNNING_SERVERLESS=1 DOMAINNAME=reddit-resolver.invalid
# Debian package versions are recorded in the image, including ffmpeg libraries.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && mkdir -p /opt/versions \
    && ffmpeg -version > /opt/versions/ffmpeg.txt \
    && ffprobe -version > /opt/versions/ffprobe.txt \
    && dpkg-query -W > /opt/versions/debian-packages.lock \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --no-log-init --uid 10003 --user-group --no-create-home --shell /usr/sbin/nologin resolver
COPY --from=build /opt/python /opt/python
COPY --from=build /opt/vxreddit /opt/vxreddit
WORKDIR /service
COPY Telegram/reddit-resolver/service.py Telegram/reddit-resolver/upstream_adapter.py \
     Telegram/reddit-resolver/healthcheck.py ./
COPY Telegram/reddit-resolver/requirements.lock /opt/versions/requirements.lock
USER 10003:10003
EXPOSE 9813
HEALTHCHECK --interval=30s --timeout=4s --start-period=5s --retries=3 CMD ["python", "/service/healthcheck.py"]
CMD ["python", "/service/service.py"]
