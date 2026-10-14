"""Fetch the band's auth key from Xiaomi by replaying Mi Fitness's device-list call.

Reuses the session recorded in a mitmproxy capture (see `mitm/export_source_list_request.py`),
so it works only while that Mi Fitness login is still valid. The key is written to a
protected file and never printed.

Usage:
  python3 fetcher/scripts/fetch_band_key.py fetcher/capture/source_list_request.json \
      fetcher/capture/band_authkey.hex
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from band10.vendor_huami.mi_crypto import (  # noqa: E402
    _sha1_sign,
    derive_rc4_key,
    generate_nonce,
    mi_decrypt_response,
    mi_encrypt_params,
)

BAND_MODEL_PREFIX = "miwear.watch."
AUTH_KEY_PATTERN = re.compile(r"[0-9a-fA-F]{32}")
REQUEST_TIMEOUT_SECONDS = 20
HEADERS_SET_BY_CLIENT = {"content-length", "accept-encoding", "host"}


class KeyFetchError(Exception):
    """The key could not be fetched; the message says why."""


def find_signing_path(recorded: dict) -> str:
    """The path Mi Fitness signs is the URL path minus a per-service prefix; find
    which suffix reproduces the hash recorded in the capture."""
    rc4_key = derive_rc4_key(recorded["ssecurity"], recorded["captured_nonce"])
    plain = {k: v for k, v in recorded["plain_params"].items() if k != "rc4_hash__"}
    segments = recorded["path"].strip("/").split("/")
    candidates = ["/" + "/".join(segments[index:]) for index in range(len(segments))]
    for candidate in candidates:
        if _sha1_sign(recorded["method"], candidate, dict(sorted(plain.items())), rc4_key) == recorded["plain_params"]["rc4_hash__"]:
            return candidate
    raise KeyFetchError("none of the candidate signing paths reproduces the recorded hash")


def request_device_list(recorded: dict, signing_path: str) -> dict:
    nonce = generate_nonce()
    plain = {k: v for k, v in recorded["plain_params"].items() if k != "rc4_hash__"}
    encrypted = mi_encrypt_params(recorded["method"], signing_path, plain, nonce, recorded["ssecurity"])
    headers = {k: v for k, v in recorded["headers"] if k.lower() not in HEADERS_SET_BY_CLIENT}
    url = f"{recorded['scheme']}://{recorded['host']}{recorded['path']}"
    request = urllib.request.Request(
        url, data=urllib.parse.urlencode(encrypted).encode(), headers=headers, method=recorded["method"]
    )
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8").strip()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:200]
        raise KeyFetchError(f"server answered HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise KeyFetchError(f"request failed: {error.reason}") from error
    try:
        return json.loads(mi_decrypt_response(body, nonce, recorded["ssecurity"]))
    except (ValueError, UnicodeDecodeError) as error:
        raise KeyFetchError(f"reply could not be decrypted (session expired?): {body[:120]}") from error


def find_band(device_list: dict) -> tuple[dict, str]:
    devices = (device_list.get("result") or {}).get("list") or []
    for device in devices:
        key = (device.get("detail") or {}).get("encrypt_key", "")
        if str(device.get("model", "")).startswith(BAND_MODEL_PREFIX) and AUTH_KEY_PATTERN.fullmatch(key):
            return device, key.lower()
    summary = [(d.get("model"), bool((d.get("detail") or {}).get("encrypt_key"))) for d in devices]
    raise KeyFetchError(f"no paired band with a key in the device list: {summary}")


def write_key(path: Path, key: str) -> bool:
    """Writes the key with owner-only permissions; returns whether it changed."""
    previous = path.read_text(encoding="utf-8").strip() if path.exists() else ""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(key + "\n")
    return key != previous


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print(__doc__)
        return 2
    recorded_path, key_path = Path(arguments[0]), Path(arguments[1])
    try:
        recorded = json.loads(recorded_path.read_text(encoding="utf-8"))
        signing_path = find_signing_path(recorded)
        device_list = request_device_list(recorded, signing_path)
        device, key = find_band(device_list)
    except (OSError, ValueError, KeyError) as error:
        print(f"FAILED: cannot use {recorded_path}: {error}")
        return 1
    except KeyFetchError as error:
        print(f"FAILED: {error}")
        return 1
    detail = device.get("detail") or {}
    changed = write_key(key_path, key)
    print(f"OK band {str(device.get('name')).strip()} ({device.get('model')}) mac {detail.get('mac')} "
          f"last_bind_time {detail.get('last_bind_time')} key_changed={changed} -> {key_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
