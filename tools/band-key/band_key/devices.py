"""Reads the wearables of a Xiaomi account and their Bluetooth auth keys.

Mi Fitness lists the paired devices with `POST /app/v1/source/get_source_list`
on the regional health host. Each wearable carries `detail.encrypt_key`: the
16-byte key, as 32 hex digits, that authenticates every Bluetooth session with
the band. Only the `serviceToken` cookie and the `ssecurity` from the login are
needed; the request and the reply are RC4-encrypted (see crypto.py).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from . import crypto
from .web import Web, WebError

# Regional hosts of the Mi Fitness health cloud. An account lives in one region.
REGIONS = ("de", "sg", "us", "ru", "i2", "cn")
_PATH = "/app/v1/source/get_source_list"
_PAGE = {"page_size": 50, "status": 1, "page_start": ""}
_KEY = re.compile(r"[0-9a-fA-F]{32}")
_USER_AGENT = "band-key (Mi Fitness device list)"


@dataclass(frozen=True)
class Wearable:
    name: str
    model: str
    mac: str
    key: str
    region: str


class CloudError(Exception):
    """The health cloud could not be read; the message says why."""


def host(region: str) -> str:
    return "hlth.io.mi.com" if region == "cn" else f"{region}.hlth.io.mi.com"


def wearables_in(reply: dict, region: str) -> list[Wearable]:
    """The devices of a decrypted device-list reply that carry an auth key."""
    found = []
    for device in (reply.get("result") or {}).get("list") or []:
        detail = device.get("detail") or {}
        key = str(detail.get("encrypt_key") or "")
        if _KEY.fullmatch(key):
            found.append(Wearable(
                name=str(device.get("name") or "").strip() or "?",
                model=str(device.get("model") or "?"),
                mac=str(detail.get("mac") or "?").upper(),
                key=key.lower(),
                region=region,
            ))
    return found


def list_wearables(service_token: str, ssecurity: str, region: str) -> list[Wearable]:
    """Asks one region for the account's devices."""
    nonce = crypto.new_nonce()
    form = crypto.encrypt_params("POST", _PATH, {"data": json.dumps(_PAGE, separators=(",", ":"))}, nonce, ssecurity)
    try:
        response = Web(_USER_AGENT).request(
            "POST", f"https://{host(region)}{_PATH}", data=form, headers={"Cookie": f"serviceToken={service_token}"}
        )
    except WebError as error:
        raise CloudError(str(error)) from error
    if response.status != 200:
        raise CloudError(f"{host(region)} answered HTTP {response.status}")
    try:
        reply = json.loads(crypto.decrypt_response(response.text.strip(), nonce, ssecurity))
    except (ValueError, UnicodeDecodeError) as error:
        raise CloudError(f"{host(region)} sent a reply that does not decrypt") from error
    if reply.get("code") not in (0, None):
        raise CloudError(f"{host(region)} refused: {reply.get('message') or reply.get('code')}")
    return wearables_in(reply, region)
