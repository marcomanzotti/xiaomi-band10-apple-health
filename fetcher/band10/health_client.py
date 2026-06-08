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
    """Adds health-data calls on top of the vendored XiaomiClient."""

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


def make_client(username: str, password: str, region: str = "de") -> HealthClient:
    """Log in and return a ready HealthClient.

    region: Xiaomi cloud region subdomain. Common: 'de' (Europe), 'sg', 'us', 'ru'.
            Pick the one matching your Mi account's server region.
    """
    session = XiaomiSession(username, password)
    session.login()
    return HealthClient(session, region=region)
