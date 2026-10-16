"""A small HTTP client on the standard library, so the tool needs no install.

It keeps cookies across requests and redirects, and can stop at a redirect to
read its headers (the login hands out `ssecurity` in one of them).
"""

from __future__ import annotations

import http.cookiejar
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from email.message import Message

_TIMEOUT_SECONDS = 20


class WebError(Exception):
    """The server could not be reached."""


@dataclass(frozen=True)
class Reply:
    status: int
    headers: Message
    body: bytes = field(repr=False)

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def header(self, name: str) -> str:
        return self.headers.get(name) or ""


class _KeepRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401, ANN001
        return None


class Web:
    def __init__(self, user_agent: str) -> None:
        self._user_agent = user_agent
        self._jar = http.cookiejar.CookieJar()
        cookies = urllib.request.HTTPCookieProcessor(self._jar)
        self._following = urllib.request.build_opener(cookies)
        self._stopping = urllib.request.build_opener(cookies, _KeepRedirect())

    def set_cookie(self, name: str, value: str, domain: str) -> None:
        self._jar.set_cookie(http.cookiejar.Cookie(
            0, name, value, None, False, domain, True, domain.startswith("."), "/", True,
            False, None, False, None, None, {},
        ))

    def cookie(self, name: str, prefer_domain: str = "") -> str:
        """The cookie's value; with `prefer_domain`, one set for a domain containing it wins."""
        found = [c for c in self._jar if c.name == name and c.value]
        preferred = [c for c in found if prefer_domain and prefer_domain in c.domain]
        return (preferred or found)[0].value if found else ""

    def request(
        self,
        method: str,
        url: str,
        params: dict[str, str] | None = None,
        data: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
        follow_redirects: bool = True,
    ) -> Reply:
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("User-Agent", self._user_agent)
        if body is not None:
            request.add_header("Content-Type", "application/x-www-form-urlencoded")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        opener = self._following if follow_redirects else self._stopping
        try:
            with opener.open(request, timeout=_TIMEOUT_SECONDS) as response:
                return Reply(response.status, response.headers, response.read())
        except urllib.error.HTTPError as error:
            # Redirects not followed and error statuses still carry a usable reply.
            return Reply(error.code, error.headers, error.read())
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            raise WebError(f"cannot reach {urllib.parse.urlparse(url).hostname} ({error.__class__.__name__})") from error
