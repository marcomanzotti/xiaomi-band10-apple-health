"""Xiaomi Mi Account login WITH identity-verification (securityStatus 16) support.

The vendored huami-token XiaomiSession handles the happy path, but Xiaomi forces
an identity-verification step (`securityStatus: 16` + `notificationUrl`) when
logging in to `miothealth` from an unrecognized device. This module implements
the full flow — adapted from PiotrMachowski/Xiaomi-cloud-tokens-extractor
(2FA email/SMS) — keyed to sid=miothealth, using a single persistent
`requests.Session` so the deviceId + cookies carry through.

Result: a logged-in session exposing `ssecurity`, `service_token`, `user_id`,
`c_user_id` — compatible with band10's HealthClient.

Flow:
  1. GET  serviceLogin?sid=miothealth        -> _sign
  2. POST serviceLoginAuth2 (user+passhash)  -> ssecurity OR notificationUrl
  3a. if ssecurity present: done (visit location for serviceToken)
  3b. if notificationUrl:   identity verification
        - GET  identity/list?context=...     -> available methods + ick cookie
        - POST identity/auth/send{Email,Phone}Ticket  (sends code)
        - user enters code
        - POST identity/auth/verify{Email,Phone}       (trust=true to remember)
        - follow redirect -> ssecurity from `extension-pragma` header
        - visit STS location -> serviceToken cookie
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.parse
from pathlib import Path
from typing import Any

import requests
from loguru import logger
from requests.cookies import create_cookie

from .vendor_huami.errors import AuthenticationError

SID = "miothealth"

# Where the persisted session (cookies + ssecurity + tokens) is cached so the
# email-verification wall only has to be crossed once per device. Override with
# MI_SESSION_FILE; defaults next to the package so a fresh checkout just works.
SESSION_FILE = Path(
    os.environ.get(
        "MI_SESSION_FILE",
        str(Path(__file__).resolve().parent.parent / ".mi_session.json"),
    )
)
UA = (
    "Mozilla/5.0 (Linux; Android 12; Pixel 4 Build/SP1A.210812.016.C1; wv) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.200 "
    "Mobile Safari/537.36"
)
ACCOUNT = "https://account.xiaomi.com"


def _device_id(seed: str) -> str:
    return "an_" + hashlib.md5(seed.encode()).hexdigest()


def _parse_xiaomi_json(text: str) -> dict[str, Any]:
    prefix = "&&&START&&&"
    if text.startswith(prefix):
        text = text[len(prefix):]
    return json.loads(text)


class XiaomiSession2FA:
    """Login session that survives the securityStatus-16 verification wall."""

    def __init__(self, username: str, password: str) -> None:
        self.username = username
        self.password = password
        self.device_id = _device_id(username)

        self._s = requests.Session()
        self._s.headers.update({"User-Agent": UA})
        # Persistent cookies — the key to making verification stick to our device.
        self._s.cookies.set("userId", username, domain="account.xiaomi.com")
        self._s.cookies.set("deviceId", self.device_id, domain="account.xiaomi.com")
        self._s.cookies.set("deviceId", self.device_id, domain=".mi.com")
        self._s.cookies.set("sdkVersion", "accountsdk-18.8.15", domain=".mi.com")

        self._ssecurity: str | None = None
        self._service_token: str | None = None
        self._user_id: str | None = None
        self._c_user_id: str | None = None
        self._nonce: int | None = None
        self._time_diff: int = 0

    # ---- public properties matching XiaomiSession ----
    @property
    def ssecurity(self) -> str:
        if not self._ssecurity:
            raise AuthenticationError(message="Not logged in — no ssecurity")
        return self._ssecurity

    @property
    def service_token(self) -> str:
        if not self._service_token:
            raise AuthenticationError(message="Not logged in — no service_token")
        return self._service_token

    @property
    def user_id(self) -> str:
        if not self._user_id:
            raise AuthenticationError(message="Not logged in — no user_id")
        return self._user_id

    @property
    def c_user_id(self) -> str:
        return self._c_user_id or ""

    # ---- session persistence (avoids re-doing email verification every run) ----
    def _save_session(self) -> None:
        try:
            data = {
                "username": self.username,
                "device_id": self.device_id,
                "ssecurity": self._ssecurity,
                "service_token": self._service_token,
                "user_id": self._user_id,
                "c_user_id": self._c_user_id,
                "cookies": [
                    {"name": c.name, "value": c.value, "domain": c.domain, "path": c.path}
                    for c in self._s.cookies
                ],
            }
            SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
            SESSION_FILE.write_text(json.dumps(data))
            SESSION_FILE.chmod(0o600)
            logger.debug(f"Session cached to {SESSION_FILE}")
        except Exception as e:  # noqa: BLE001
            logger.debug(f"Could not cache session: {e}")

    def _load_session(self) -> bool:
        """Try to restore a cached session. Returns True if it looks usable."""
        if not SESSION_FILE.exists():
            return False
        try:
            data = json.loads(SESSION_FILE.read_text())
        except Exception:  # noqa: BLE001
            return False
        if data.get("username") != self.username:
            return False

        for ck in data.get("cookies", []):
            if ck.get("value"):
                self._s.cookies.set_cookie(
                    create_cookie(name=ck["name"], value=ck["value"], domain=ck.get("domain", ""), path=ck.get("path", "/"))
                )
        self._ssecurity = data.get("ssecurity")
        self._service_token = data.get("service_token")
        self._user_id = data.get("user_id")
        self._c_user_id = data.get("c_user_id")
        return bool(self._ssecurity and self._service_token and self._user_id)

    # ---- flow ----
    def login(self) -> None:
        if self._load_session():
            logger.info(f"Reusing cached session for {self.username} (no verification needed).")
            return
        logger.info("Logging in to Xiaomi (2FA-aware)…")
        sign, qs, callback = self._step1_sign()
        data = self._step2_auth(sign, qs, callback)

        if data.get("ssecurity") and data.get("location"):
            self._absorb_auth(data)
            self._get_service_token(data["location"])
            logger.info(f"Logged in (no verification). user_id={self._user_id}")
            self._save_session()
            return

        notif = data.get("notificationUrl")
        if not notif:
            raise AuthenticationError(
                code="no-ssecurity",
                message=(
                    f"No ssecurity and no notificationUrl. "
                    f"code={data.get('code')} desc={data.get('desc') or data.get('description')} "
                    f"Fields: {list(data.keys())}"
                ),
            )
        logger.warning("Identity verification required (securityStatus 16).")
        self._verify_identity(notif)
        logger.info(f"Logged in after verification. user_id={self._user_id}")
        self._save_session()

    def _step1_sign(self) -> tuple[str, str, str]:
        """Returns (_sign, qs, callback) — must reuse Xiaomi's qs/callback,
        otherwise the _sign won't match and auth returns no ssecurity/notif."""
        r = self._s.get(
            f"{ACCOUNT}/pass/serviceLogin",
            params={"sid": SID, "_json": "true", "_locale": "en_US"},
        )
        d = _parse_xiaomi_json(r.text)
        sign = d.get("_sign")
        if not sign:
            raise AuthenticationError(message=f"No _sign in step1: {list(d.keys())}")
        return sign, d.get("qs", ""), d.get("callback", "")

    def _step2_auth(self, sign: str, qs: str, callback: str) -> dict[str, Any]:
        pwd_hash = hashlib.md5(self.password.encode()).hexdigest().upper()
        fields = {
            "sid": SID,
            "hash": pwd_hash,
            "callback": callback,
            "qs": qs,
            "user": self.username,
            "_sign": sign,
            "_json": "true",
            "_locale": "en_US",
        }
        r = self._s.post(f"{ACCOUNT}/pass/serviceLoginAuth2", data=fields)
        return _parse_xiaomi_json(r.text)

    def _absorb_auth(self, data: dict[str, Any]) -> None:
        self._ssecurity = data.get("ssecurity")
        self._nonce = data.get("nonce")
        self._user_id = str(data.get("userId", "")) or self._user_id
        self._c_user_id = data.get("cUserId") or self._c_user_id

    def _verify_identity(self, notification_url: str) -> None:
        # Open the notification URL within OUR session (same deviceId/cookies).
        self._s.get(notification_url)
        ctx = urllib.parse.parse_qs(urllib.parse.urlparse(notification_url).query)
        context = ctx.get("context", [""])[0]

        # Discover available verification methods.
        r = self._s.get(
            f"{ACCOUNT}/identity/list",
            params={"sid": SID, "context": context, "_locale": "en_US"},
        )
        methods_raw = r.text
        use_phone = "phone" in methods_raw.lower() and "email" not in methods_raw.lower()
        kind = "Phone" if use_phone else "Email"
        logger.info(f"Verification method: {kind}")

        ick = self._s.cookies.get("ick", "")
        # Send the ticket (code) to email/phone.
        send_params = {
            "_dc": str(int(time.time() * 1000)),
            "sid": SID,
            "context": context,
            "mask": "0",
            "_locale": "en_US",
        }
        send_data = {"retry": "0", "icode": "", "_json": "true", "ick": ick}
        self._s.post(
            f"{ACCOUNT}/identity/auth/send{kind}Ticket",
            params=send_params,
            data=send_data,
        )

        code = input(f"Inserisci il codice ricevuto via {kind.lower()}: ").strip()

        verify_params = {
            "_flag": "8",
            "_json": "true",
            "sid": SID,
            "context": context,
            "mask": "0",
            "_locale": "en_US",
        }
        verify_data = {
            "_flag": "8",
            "ticket": code,
            "trust": "true",  # remember this device → no re-verify next time
            "_json": "true",
            "ick": self._s.cookies.get("ick", ick),
        }
        vr = self._s.post(
            f"{ACCOUNT}/identity/auth/verify{kind}",
            params=verify_params,
            data=verify_data,
        )
        vd = _parse_xiaomi_json(vr.text)
        if vd.get("code") not in (0, None):
            raise AuthenticationError(
                code="verify-failed",
                message=f"Verification failed: {vd.get('desc') or vd.get('description') or vd}",
            )

        # After verification the response gives a location to continue auth.
        location = vd.get("location")
        if not location:
            raise AuthenticationError(
                message=f"No location after verification: {list(vd.keys())}"
            )

        # Follow the redirect chain manually, inspecting every hop for
        # `extension-pragma` (it may not be on the very first response).
        url = location
        for _ in range(10):
            rr = self._s.get(url, allow_redirects=False)
            logger.debug(
                f"[verify-redirect] GET {url} -> {rr.status_code} "
                f"headers={dict(rr.headers)}"
            )
            ext = rr.headers.get("extension-pragma") or rr.headers.get("Extension-Pragma")
            if ext and not self._ssecurity:
                try:
                    self._ssecurity = json.loads(ext).get("ssecurity")
                    logger.info("Captured ssecurity from extension-pragma header.")
                except Exception:  # noqa: BLE001
                    pass

            nxt = rr.headers.get("Location")
            if not nxt:
                break
            url = nxt

        self._user_id = self._user_id or self._cookie("userId")

        if not self._ssecurity:
            try:
                vd_extra = json.loads(rr.text)
                logger.debug(f"[verify-final-body] {vd_extra}")
            except Exception:  # noqa: BLE001
                logger.debug(f"[verify-final-body raw] {rr.text[:500]}")
            raise AuthenticationError(
                message="Verification done but ssecurity not captured. "
                "Inspect headers — flow may need adjustment."
            )

        # Final hop should have set the serviceToken cookie (or redirected to STS).
        self._get_service_token(url)

    def _cookie(self, name: str) -> str:
        """Get a cookie value tolerating the same name across multiple domains."""
        vals = [c.value for c in self._s.cookies if c.name == name and c.value]
        return vals[0] if vals else ""

    def _get_service_token(self, location: str) -> None:
        self._s.get(location, allow_redirects=True)
        token = self._cookie("serviceToken")
        if token:
            self._service_token = token
        self._user_id = self._user_id or self._cookie("userId")
        self._c_user_id = self._c_user_id or self._cookie("cUserId")
