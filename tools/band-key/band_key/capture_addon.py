"""mitmproxy addon: prints the band key while Mi Fitness logs in on your phone.

The fallback when `get_band_key.py` cannot log in (for example an account that
only signs in with Google or Apple). Run

    mitmdump -q --allow-hosts 'xiaomi\\.com|mi\\.com' -s band_key/capture_addon.py

route the phone through the proxy, log out of Mi Fitness and log in again.
The addon keeps the `ssecurity` of each login reply (Mi Fitness logs in to
several services in a row) and decrypts the device list the app requests right
after with whichever one fits. Nothing is written to disk.
It also works offline on a saved capture: `mitmdump -nr flows.mitm -s ...`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from band_key import crypto  # noqa: E402
from band_key.devices import wearables_in  # noqa: E402

_JSON_PREFIX = "&&&START&&&"
_DEVICE_LIST_PATH = "/app/v1/source/get_source_list"


class BandKeyCapture:
    def __init__(self) -> None:
        self._ssecurities: list[str] = []
        self._printed: set[str] = set()

    def response(self, flow) -> None:  # mitmproxy hook
        host, path = flow.request.pretty_host, flow.request.path.split("?")[0]
        if host.endswith("account.xiaomi.com") and path.startswith("/pass/serviceLogin"):
            self._read_login(flow)
        elif path == _DEVICE_LIST_PATH and flow.response is not None:
            self._read_device_list(flow, host)

    def _read_login(self, flow) -> None:
        found = None
        pragma = flow.response.headers.get("extension-pragma") if flow.response else None
        if pragma:
            found = json.loads(pragma).get("ssecurity")
        if not found and flow.response is not None:
            try:
                found = json.loads(flow.response.get_text().replace(_JSON_PREFIX, "", 1)).get("ssecurity")
            except ValueError:
                found = None
        if found and found not in self._ssecurities:
            self._ssecurities.append(found)
            print("[band-key] Mi Fitness logged in; waiting for its device list…")

    def _read_device_list(self, flow, host: str) -> None:
        nonce = flow.request.urlencoded_form.get("_nonce") or flow.request.query.get("_nonce")
        if not (self._ssecurities and nonce):
            print("[band-key] device list seen before the login: log out of Mi Fitness and log in again")
            return
        reply = self._decrypt(flow.response.get_text().strip(), nonce)
        if reply is None:
            print("[band-key] could not decrypt the device list (was the login captured?)")
            return
        for band in wearables_in(reply, host.split(".")[0]):
            if band.key not in self._printed:
                self._printed.add(band.key)
                print(f"[band-key] {band.name} ({band.model}, MAC {band.mac})  key: {band.key}")


    def _decrypt(self, body: str, nonce: str) -> dict | None:
        for ssecurity in reversed(self._ssecurities):
            try:
                return json.loads(crypto.decrypt_response(body, nonce, ssecurity))
            except (ValueError, UnicodeDecodeError):
                continue
        return None


addons = [BandKeyCapture()]
