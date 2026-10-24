"""Local counts only; never resolve a Facebook URL as a health probe."""
import json
import sys
from urllib.request import ProxyHandler, build_opener


def main():
    try:
        with build_opener(ProxyHandler({})).open('http://127.0.0.1:9812/healthz', timeout=3) as response:
            payload = json.loads(response.read(4096))
        return 0 if payload['status'] == 'ok' and all(
            type(payload[key]) is int and payload[key] >= 0
            for key in ('requests', 'errors', 'uptime_secs')
        ) else 1
    except Exception:
        return 1


if __name__ == '__main__':
    sys.exit(main())
