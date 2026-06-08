"""Diagnostic: dump the raw serviceLoginAuth2 response to see what Xiaomi wants.

Run: .venv/bin/python debug_auth.py
Uses MI_USER / MI_PASS env vars. Prints the response JSON with the password
field never shown. Redacts ssecurity/passToken if present.
"""

import hashlib
import json
import os

import requests

from band10.vendor_huami.constants import XIAOMI_HEADERS, XIAOMI_URLS
from band10.vendor_huami.xiaomi import _generate_device_id, _parse_xiaomi_json

user = os.environ["MI_USER"]
pw = os.environ["MI_PASS"]
device_id = _generate_device_id(user)

# Step 1
r1 = requests.get(
    XIAOMI_URLS.SERVICE_LOGIN.value,
    params={"_json": "true", "sid": "miothealth", "_locale": "en_US"},
    headers=XIAOMI_HEADERS.SERVICE_LOGIN.value,
    cookies={"userId": user, "deviceId": device_id},
)
d1 = _parse_xiaomi_json(r1.text)
print("STEP1 keys:", list(d1.keys()))

# Step 2
pwd_hash = hashlib.md5(pw.encode()).hexdigest().upper()
r2 = requests.post(
    XIAOMI_URLS.SERVICE_LOGIN_AUTH2.value,
    data={
        "qs": d1.get("qs"),
        "callback": d1.get("callback"),
        "_json": "true",
        "_sign": d1.get("_sign"),
        "user": user,
        "hash": pwd_hash,
        "sid": "miothealth",
        "_locale": "en_US",
    },
    headers=XIAOMI_HEADERS.SERVICE_LOGIN_AUTH2.value,
    cookies={"deviceId": device_id},
)
d2 = _parse_xiaomi_json(r2.text)

# Redact sensitive fields, keep diagnostic ones.
for k in ("ssecurity", "passToken", "psecurity"):
    if k in d2:
        d2[k] = f"<present:{len(str(d2[k]))} chars>"

print("\nSTEP2 full response:")
print(json.dumps(d2, indent=2, ensure_ascii=False))
print("\nKey diagnostic fields:")
for k in ("code", "result", "description", "desc", "notificationUrl", "captchaUrl", "location"):
    if k in d2:
        print(f"  {k}: {d2[k]}")
