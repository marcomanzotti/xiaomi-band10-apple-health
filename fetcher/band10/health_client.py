"""Health-data client for the Xiaomi mi.com health cloud.

Builds on the vendored huami-token XiaomiClient (login + RC4 crypto) and adds
methods to fetch sleep / heart-rate / SpO2 / HRV data.

IMPORTANT: The exact endpoint paths and parameter shapes for health data on
`*.hlth.io.mi.com` are NOT publicly documented. This module ships a set of
*candidate* endpoints derived from the known pathPrefix values in mi_crypto.py
and from the older huami.com `band_data.json` schema. Use `probe_endpoints()`
to discover which ones your account/region actually answers, and use
`scripts/capture_help.md` if probing fails (mitmproxy capture).

Once a working endpoint is confirmed, pin it in WORKING_ENDPOINTS below.
"""

from __future__ import annotations

import json
from datetime import date
from typing import Any

import requests
from loguru import logger

from .vendor_huami.xiaomi import XiaomiClient, XiaomiSession


# Filled in once probing/capture confirms the real path + params.
# Example shape:
#   {"name": "sleep", "url": "...", "method": "GET", "path_prefix": "healthapp/",
#    "params_builder": lambda uid, d0, d1: {"data": json.dumps({...})}}
WORKING_ENDPOINTS: dict[str, dict[str, Any]] = {}


def _epoch_day(d: date) -> int:
    """Days since Unix epoch (some Xiaomi health APIs key data by this)."""
    return (d - date(1970, 1, 1)).days


class HealthClient(XiaomiClient):
    """Adds health-data calls on top of the vendored XiaomiClient.

    CONFIRMED from live capture: data endpoints require an `auth_key` cookie
    (the Band's pairing key, obtained from `get_source_list` status=1) — without
    it the server returns HTTP 401 `{"code":0,"message":"auth err"}` even though
    the request is correctly signed/encrypted with a valid serviceToken.
    """

    # Candidate endpoints to probe. Each entry: how to build the URL + params.
    # `region` subdomain is substituted at call time.
    # CONFIRMED from live mitmproxy capture of Mi Fitness 3.49.0 (iOS) talking
    # to the Band 10, region `de`. All are POST to `{region}.hlth.io.mi.com`
    # with an RC4-encrypted `data` form field and a `serviceToken` cookie.
    # The sleep/vitals time-series comes from `get_fitness_data_by_watermark`.
    CANDIDATES: list[dict[str, Any]] = [
        {
            "name": "get_fitness_data_by_watermark",
            "path": "/app/v1/data/get_fitness_data_by_watermark",
            "method": "POST",
            "path_prefix": "app/v1/",
            "regional": True,
        },
        {
            "name": "get_aggregated_fitness_data_by_watermark",
            "path": "/app/v1/data/get_aggregated_fitness_data_by_watermark",
            "method": "POST",
            "path_prefix": "app/v1/",
            "regional": True,
        },
        {
            "name": "get_stat_data_by_time",
            "path": "/app/v1/statistics/get_stat_data_by_time",
            "method": "POST",
            "path_prefix": "app/v1/",
            "regional": True,
        },
    ]

    def __init__(self, session: Any, region: str = "de") -> None:
        super().__init__(session, region=region)
        self._auth_key: str | None = None

    @property
    def auth_key(self) -> str:
        """The Band's pairing key (cookie required by data endpoints).

        Lazily fetched + cached via `get_source_list(status=1)`.
        """
        if self._auth_key is None:
            import os

            env_key = os.environ.get("MI_AUTH_KEY")
            if env_key:
                self._auth_key = env_key
            else:
                resp = self.get_source_list(status=1)
                result = resp.get("result") or {}
                devices = result.get("list") or result.get("items") or []
                for dev in devices:
                    key = (dev.get("detail") or {}).get("auth_key") or dev.get("auth_key")
                    if key:
                        self._auth_key = key
                        break
                if self._auth_key is None:
                    raise RuntimeError(
                        "No auth_key found via get_source_list (response had no bound "
                        "devices, or its shape differs from expected). Set MI_AUTH_KEY "
                        f"manually (see README) to skip discovery. Raw result: {result}"
                    )
            logger.info(f"Resolved device auth_key (len={len(self._auth_key)}).")
        return self._auth_key

    def _build_cookies(self) -> dict[str, str]:
        cookies = super()._build_cookies()
        # CONFIRMED capture used `locale=en` (not `en_us`) alongside `auth_key`.
        cookies["locale"] = "en"
        # Avoid recursion: get_source_list (used to resolve auth_key) must not
        # require auth_key itself.
        if self._auth_key is not None:
            cookies["auth_key"] = self._auth_key
        return cookies

    def _build_headers(self) -> dict[str, str]:
        # The data endpoints expect an iOS Mi Fitness User-Agent — the generic
        # Android UA the vendored client ships with gets a 401 `auth err`.
        # Format observed in capture (Mi Fitness 3.49.0 on iOS):
        #   iOS-<os_version>-<app_version>-<device_model>-<device_model>-<hash1>-<hash2>
        # The two trailing hashes are per-device/install identifiers; override
        # via MI_USER_AGENT with your own captured value if this generic form
        # gets rejected.
        import os as _os

        headers = super()._build_headers()
        headers["User-Agent"] = _os.environ.get(
            "MI_USER_AGENT",
            "iOS-17.0-3.49.0-iPhone-iPhone-0000000000000000000000000000000000000000-"
            "00000000000000000000000000000000",
        )
        headers.pop("region_tag", None)
        return headers

    def _base_domain(self, regional: bool) -> str:
        # Capture shows health data on the REGIONAL host (de.hlth.io.mi.com).
        return f"{self.region}.hlth.io.mi.com" if regional else "hlth.io.mi.com"

    def _date_params(self, from_date: date, to_date: date) -> dict[str, str]:
        """A reasonable default param payload; adjusted per discovery."""
        data = json.dumps(
            {
                "userid": self.session.user_id,
                "from": from_date.isoformat(),
                "to": to_date.isoformat(),
                "from_day": _epoch_day(from_date),
                "to_day": _epoch_day(to_date),
                "data_type": "sleep",
            },
            separators=(",", ":"),
        )
        return {"data": data}

    def request(  # type: ignore[override]
        self,
        method: str,
        url: str,
        params: dict[str, str] | None = None,
        path_prefix: str = "",
        extra_query: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Like XiaomiClient.request, but tolerates plaintext JSON responses.

        CONFIRMED from capture: `/app/v1/data/...` responses are plain
        (gzip-transport-compressed, auto-decoded by `requests`) JSON — only the
        request `data` is RC4-encrypted. The vendored client assumes symmetric
        encryption and fails to base64-decode these. We try plaintext JSON
        first, then fall back to RC4 decryption for endpoints that need it.
        """
        import urllib.parse as _up

        from .vendor_huami.mi_crypto import (
            compute_signing_path,
            generate_nonce,
            mi_decrypt_response,
            mi_encrypt_params,
        )

        parsed = _up.urlparse(url)
        signing_path = compute_signing_path(parsed.path, path_prefix)
        nonce_b64 = generate_nonce(self.session._time_diff)
        encrypted = mi_encrypt_params(
            method=method,
            signing_path=signing_path,
            params=params or {},
            nonce_b64=nonce_b64,
            ssecurity_b64=self.session.ssecurity,
        )
        if extra_query:
            encrypted = {**extra_query, **encrypted}

        cookies = self._build_cookies()
        headers = self._build_headers()

        if method.upper() == "GET":
            response = requests.get(url, params=encrypted, cookies=cookies, headers=headers)
        else:
            response = requests.post(url, data=encrypted, cookies=cookies, headers=headers)

        body = response.text
        try:
            return json.loads(body)
        except Exception:  # noqa: BLE001
            pass
        decrypted = mi_decrypt_response(body, nonce_b64, self.session.ssecurity)
        return json.loads(decrypted)

    def probe_endpoints(self, from_date: date, to_date: date) -> dict[str, Any]:
        """Try each candidate endpoint, return a report of what responded.

        A "hit" is any non-error decrypted JSON. We don't assume schema yet —
        we just want to know which path the server accepts so we can inspect
        its shape.
        """
        report: dict[str, Any] = {}
        params = self._date_params(from_date, to_date)

        for cand in self.CANDIDATES:
            url = f"https://{self._base_domain(cand['regional'])}{cand['path']}"
            try:
                resp = self.request(
                    cand["method"],
                    url,
                    params=params,
                    path_prefix=cand["path_prefix"],
                    extra_query={"locale": "en_us"},
                )
                code = resp.get("code", resp.get("retCode"))
                report[cand["name"]] = {
                    "url": url,
                    "ok": True,
                    "code": code,
                    "keys": list(resp.keys())[:20],
                    "sample": resp,
                }
                logger.info(f"[probe] {cand['name']}: responded (code={code})")
            except Exception as e:  # noqa: BLE001 - probing, want all failures
                report[cand["name"]] = {
                    "url": url,
                    "ok": False,
                    "error": f"{type(e).__name__}: {e}",
                }
                logger.debug(f"[probe] {cand['name']}: {type(e).__name__}: {e}")

        return report

    def fetch_sleep(self, from_date: date, to_date: date) -> dict[str, Any]:
        """Fetch sleep data using a confirmed endpoint.

        Raises if no working endpoint has been pinned in WORKING_ENDPOINTS.
        """
        if "sleep" not in WORKING_ENDPOINTS:
            raise NotImplementedError(
                "No confirmed sleep endpoint yet. Run `band10 probe` (or capture "
                "Mi Fitness traffic) and pin the result in WORKING_ENDPOINTS."
            )
        ep = WORKING_ENDPOINTS["sleep"]
        return self.request(
            ep["method"],
            ep["url"],
            params=ep["params_builder"](self.session.user_id, from_date, to_date),
            path_prefix=ep["path_prefix"],
            extra_query={"locale": "en_us"},
        )


def make_client(
    username: str, password: str, region: str = "de", verify: bool = True
) -> HealthClient:
    """Log in and return a ready HealthClient.

    region: Xiaomi cloud region subdomain. Common: 'de' (Europe), 'sg', 'us', 'ru'.
            Pick the one matching your Mi account's server region.
    verify: if True, use the 2FA-aware session that survives the
            `securityStatus 16` identity-verification wall (prompts for an
            email/SMS code on first login from this device).
    """
    if verify:
        from .xiaomi_2fa import XiaomiSession2FA

        session: Any = XiaomiSession2FA(username, password)
    else:
        session = XiaomiSession(username, password)
    session.login()
    return HealthClient(session, region=region)
