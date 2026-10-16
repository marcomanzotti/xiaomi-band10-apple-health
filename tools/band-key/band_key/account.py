"""Logs in to a Xiaomi account for the Mi Fitness health cloud (sid `miothealth`).

The flow is the one the official app uses: get a signature, post the password
hash, and, when Xiaomi does not recognise the computer, confirm a code sent by
email or SMS (and sometimes solve a captcha). The result is the `ssecurity`
and `serviceToken` needed to read the device list.

The verification and captcha steps are adapted from Xiaomi-cloud-tokens-extractor
by Piotr Machowski (MIT), see THIRD_PARTY_NOTICES.md.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import os
import tempfile
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .web import Reply, Web, WebError

SID = "miothealth"
ACCOUNT = "https://account.xiaomi.com"
_SDK_VERSION = "accountsdk-18.8.15"
_USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 12; Pixel 4 Build/SP1A.210812.016.C1; wv) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.200 Mobile Safari/537.36"
)
_JSON_PREFIX = "&&&START&&&"
_MAX_REDIRECTS = 10
# The health cloud's token is set by its own STS host; other services set one too.
_HEALTH_TOKEN_DOMAIN = "hlth"
_WRONG_CAPTCHA = 87001

Ask = Callable[[str], str]


@dataclass(frozen=True)
class Credentials:
    ssecurity: str
    service_token: str


class LoginError(Exception):
    """The login did not succeed; the message says why, without secrets."""


def _json(text: str) -> dict:
    try:
        return json.loads(text.replace(_JSON_PREFIX, "", 1))
    except ValueError as error:
        raise LoginError("Xiaomi sent an unexpected answer") from error


class XiaomiLogin:
    """One login attempt. `ask` asks the person for the codes Xiaomi sends."""

    def __init__(self, username: str, password: str, ask: Ask = input) -> None:
        self._username = username
        self._password_hash = hashlib.md5(password.encode()).hexdigest().upper()
        self._ask = ask
        self._ssecurity: str | None = None
        self._web = Web(_USER_AGENT)
        device_id = "".join(secrets.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(16))
        for domain in (".mi.com", ".xiaomi.com"):
            self._web.set_cookie("sdkVersion", _SDK_VERSION, domain)
            self._web.set_cookie("deviceId", device_id, domain)
        self._web.set_cookie("userId", username, "account.xiaomi.com")

    def login(self) -> Credentials:
        reply = self._authenticate(*self._signature())
        if reply.get("ssecurity") and reply.get("location"):
            self._ssecurity = reply["ssecurity"]
            self._follow(reply["location"])
        elif reply.get("notificationUrl"):
            self._verify_identity(reply["notificationUrl"])
        else:
            raise LoginError(
                f"wrong email/phone or password ({reply.get('desc') or reply.get('description') or reply.get('code')})"
            )
        return self._credentials()

    # Step 1: the login page signature, with the `qs` and `callback` it was made
    # for: the password step must send them back unchanged.
    def _signature(self) -> tuple[str, str, str]:
        page = _json(self._get(f"{ACCOUNT}/pass/serviceLogin", params={"sid": SID, "_json": "true"}).text)
        if not page.get("_sign"):
            raise LoginError("unknown account (no login signature)")
        return page["_sign"], page.get("qs", ""), page.get("callback", "")

    # Step 2: password, with an optional captcha.
    def _authenticate(self, sign: str, qs: str, callback: str) -> dict:
        fields = {
            "sid": SID,
            "hash": self._password_hash,
            "callback": callback,
            "qs": qs,
            "user": self._username,
            "_sign": sign,
            "_json": "true",
        }
        reply = _json(self._post(f"{ACCOUNT}/pass/serviceLoginAuth2", data=fields).text)
        if reply.get("captchaUrl"):
            fields["captCode"] = self._solve_captcha(reply["captchaUrl"])
            reply = _json(self._post(f"{ACCOUNT}/pass/serviceLoginAuth2", data=fields).text)
            if reply.get("code") == _WRONG_CAPTCHA:
                raise LoginError("the captcha was not accepted, try again")
        return reply

    def _solve_captcha(self, url: str) -> str:
        image = self._get(urllib.parse.urljoin(ACCOUNT, url))
        # A private file name: a predictable one in /tmp could be a planted symlink.
        descriptor, name = tempfile.mkstemp(prefix="xiaomi-captcha-", suffix=".jpg")
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(image.body)
            return self._ask(f"Xiaomi wants a captcha. Open {name} and type the characters you see: ").strip()
        finally:
            Path(name).unlink(missing_ok=True)

    # Step 3 (new computer only): a code sent by email or SMS.
    def _verify_identity(self, notification_url: str) -> None:
        self._get(notification_url)
        context = urllib.parse.parse_qs(urllib.parse.urlparse(notification_url).query).get("context", [""])[0]
        methods = self._get(f"{ACCOUNT}/identity/list", params={"sid": SID, "context": context, "_locale": "en_US"}).text.lower()
        kind = "Phone" if "phone" in methods and "email" not in methods else "Email"
        common = {"sid": SID, "context": context, "mask": "0", "_locale": "en_US"}
        self._post(
            f"{ACCOUNT}/identity/auth/send{kind}Ticket",
            params={**common, "_dc": str(int(time.time() * 1000))},
            data={"retry": "0", "icode": "", "_json": "true", "ick": self._cookie("ick")},
        )
        code = self._ask(f"Xiaomi sent a verification code by {'SMS' if kind == 'Phone' else 'email'}. Type it here: ").strip()
        reply = _json(self._post(
            f"{ACCOUNT}/identity/auth/verify{kind}",
            params={**common, "_flag": "8", "_json": "true"},
            data={"_flag": "8", "ticket": code, "trust": "true", "_json": "true", "ick": self._cookie("ick")},
        ).text)
        if reply.get("code") not in (0, None) or not reply.get("location"):
            raise LoginError(f"the code was not accepted ({reply.get('desc') or reply.get('code')})")
        self._follow(reply["location"])

    # Following the redirects collects `ssecurity` (in a header) and the serviceToken cookie.
    def _follow(self, url: str) -> None:
        for _ in range(_MAX_REDIRECTS):
            hop = self._get(url, follow_redirects=False)
            pragma = hop.header("extension-pragma")
            if pragma and not self._ssecurity:
                try:
                    self._ssecurity = json.loads(pragma).get("ssecurity")
                except ValueError:
                    pass
            next_url = hop.header("Location")
            if not next_url:
                return
            # Locations may be relative.
            url = urllib.parse.urljoin(url, next_url)
        raise LoginError("Xiaomi kept redirecting the login")

    def _credentials(self) -> Credentials:
        token = self._web.cookie("serviceToken", prefer_domain=_HEALTH_TOKEN_DOMAIN)
        if not self._ssecurity or not token:
            raise LoginError("logged in, but Xiaomi did not hand out the health-cloud session")
        return Credentials(ssecurity=self._ssecurity, service_token=token)

    def _cookie(self, name: str) -> str:
        return self._web.cookie(name)

    def _get(self, url: str, **kwargs) -> Reply:
        return self._send("GET", url, **kwargs)

    def _post(self, url: str, **kwargs) -> Reply:
        return self._send("POST", url, **kwargs)

    def _send(self, method: str, url: str, **kwargs) -> Reply:
        try:
            return self._web.request(method, url, **kwargs)
        except WebError as error:
            raise LoginError(str(error)) from error
