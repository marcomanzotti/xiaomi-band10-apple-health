"""Decrypt captured Mi Fitness flows to reveal the plaintext request/response.

The `data` form field and the response body of `*.hlth.io.mi.com/app/v1/...`
calls are RC4-encrypted with a key derived from `ssecurity` + the request's
`_nonce`. `ssecurity` is NOT in the traffic — it comes from a successful
Xiaomi login. So:

  1. Log in once with band10 (gives us `ssecurity`).
  2. Run this against the saved mitmproxy capture to see the plaintext `data`
     payloads — that reveals the exact request shape to replicate in
     health_client.fetch_sleep().

Usage:
  export MI_USER=... MI_PASS=... MI_REGION=de
  .venv/bin/python decrypt_capture.py capture/mifitness_flows.mitm

This script reads the capture with the mitmproxy library if available; if not,
it falls back to parsing a plaintext dump (see --help).
"""

from __future__ import annotations

import os
import sys
import urllib.parse

from band10.health_client import make_client
from band10.vendor_huami.mi_crypto import mi_decrypt_params, mi_decrypt_response

TARGET_SUBSTR = "/app/v1/"


def _decrypt_flow(data_field: str, nonce: str, body_b64: str, ssecurity: str) -> None:
    try:
        params = {"data": data_field}
        pt = mi_decrypt_params(params, nonce, ssecurity)
        print("  REQ data (plaintext):", pt.get("data", "")[:1000])
    except Exception as e:  # noqa: BLE001
        print("  REQ decrypt failed:", e)
    if body_b64:
        try:
            resp = mi_decrypt_response(body_b64, nonce, ssecurity)
            print("  RESP (plaintext):", resp[:2000])
        except Exception as e:  # noqa: BLE001
            print("  RESP decrypt failed:", e)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    capture_path = sys.argv[1]

    # Need ssecurity → log in.
    user = os.environ["MI_USER"]
    pw = os.environ["MI_PASS"]
    region = os.environ.get("MI_REGION", "de")
    client = make_client(user, pw, region)
    ssecurity = client.session.ssecurity
    print(f"Logged in, have ssecurity ({len(ssecurity)} chars). Reading {capture_path}…\n")

    try:
        from mitmproxy import http, io as mio  # type: ignore
    except Exception:
        print(
            "mitmproxy lib not importable here. Run this with mitmproxy's own "
            "python, or export the flows to a text dump first."
        )
        return 2

    with open(capture_path, "rb") as f:
        for fl in mio.FlowReader(f).stream():
            if not isinstance(fl, http.HTTPFlow):
                continue
            if TARGET_SUBSTR not in fl.request.path:
                continue
            body = fl.request.get_text() or ""
            qs = dict(urllib.parse.parse_qsl(body))
            data_field = qs.get("data")
            nonce = qs.get("_nonce")
            if not data_field or not nonce:
                continue
            print("=" * 70)
            print(fl.request.method, fl.request.path.split("?")[0])
            resp_b64 = fl.response.get_text() if fl.response else ""
            _decrypt_flow(data_field, nonce, resp_b64 or "", ssecurity)

    return 0


if __name__ == "__main__":
    sys.exit(main())
