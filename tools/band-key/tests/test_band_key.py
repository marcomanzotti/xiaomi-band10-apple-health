"""Tests for the band key tool. Run from tools/band-key: python3 -m unittest -v"""

from __future__ import annotations

import base64
import io
import json
import unittest
from contextlib import redirect_stdout
from email.message import Message

from band_key import crypto
from band_key.account import LoginError, XiaomiLogin
from band_key.capture_addon import BandKeyCapture
from band_key.devices import wearables_in
from band_key.web import Reply

SSECURITY = base64.b64encode(b"0123456789abcdef").decode()
KEY = "00112233445566778899aabbccddeeff"


def device_list(*devices: dict) -> dict:
    return {"code": 0, "result": {"list": list(devices)}}


def band(key: str = KEY, mac: str = "aa:bb:cc:dd:ee:ff") -> dict:
    return {"name": "Xiaomi Smart Band 10 ", "model": "miwear.watch.o66gl", "detail": {"encrypt_key": key, "mac": mac}}


def encrypted_body(text: str, nonce: str) -> str:
    cipher = crypto._cipher(crypto.request_key(SSECURITY, nonce))  # noqa: SLF001 - test helper
    return base64.b64encode(cipher.crypt(text.encode())).decode()


class CryptoTests(unittest.TestCase):
    def test_nonce_is_eight_random_bytes_and_the_minute(self) -> None:
        self.assertEqual(len(base64.b64decode(crypto.new_nonce())), 12)

    def test_parameters_decrypt_to_what_was_sent_plus_the_hash(self) -> None:
        nonce = crypto.new_nonce()
        sent = {"data": '{"page_size":50}'}

        form = crypto.encrypt_params("POST", "/app/v1/source/get_source_list", sent, nonce, SSECURITY)

        self.assertEqual(form["_nonce"], nonce)
        self.assertIn("signature", form)
        decrypted = crypto.decrypt_params(form, nonce, SSECURITY)
        self.assertEqual(decrypted["data"], sent["data"])
        self.assertIn("rc4_hash__", decrypted)

    def test_a_reply_decrypts_with_the_request_nonce(self) -> None:
        nonce = crypto.new_nonce()

        self.assertEqual(crypto.decrypt_response(encrypted_body('{"code":0}', nonce), nonce, SSECURITY), '{"code":0}')


class DeviceListTests(unittest.TestCase):
    def test_keeps_only_devices_with_a_key_and_normalises_them(self) -> None:
        reply = device_list(band(key=KEY.upper()), {"name": "Scale", "model": "x", "detail": {}}, band(key="short"))

        found = wearables_in(reply, "de")

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].key, KEY)
        self.assertEqual(found[0].name, "Xiaomi Smart Band 10")
        self.assertEqual(found[0].mac, "AA:BB:CC:DD:EE:FF")

    def test_an_empty_or_odd_reply_has_no_devices(self) -> None:
        self.assertEqual(wearables_in({"code": 0}, "de"), [])
        self.assertEqual(wearables_in({"result": {"list": None}}, "de"), [])


class _Request:
    def __init__(self, host: str, path: str, form: dict | None = None) -> None:
        self.pretty_host = host
        self.path = path
        self.urlencoded_form = form or {}
        self.query: dict = {}


class _Response:
    def __init__(self, text: str, headers: dict | None = None) -> None:
        self._text = text
        self.headers = headers or {}

    def get_text(self) -> str:
        return self._text


class _Flow:
    def __init__(self, request: _Request, response: _Response) -> None:
        self.request = request
        self.response = response


class CaptureTests(unittest.TestCase):
    def capture(self, flows: list[_Flow]) -> str:
        addon = BandKeyCapture()
        out = io.StringIO()
        with redirect_stdout(out):
            for flow in flows:
                addon.response(flow)
        return out.getvalue()

    def test_prints_the_key_from_the_device_list_after_the_login(self) -> None:
        nonce = crypto.new_nonce()
        other_login = _Flow(_Request("account.xiaomi.com", "/pass/serviceLogin?sid=xiaomiio"),
                            _Response("", {"extension-pragma": json.dumps({"ssecurity": base64.b64encode(b"x" * 16).decode()})}))
        login = _Flow(_Request("account.xiaomi.com", "/pass/serviceLoginAuth2"),
                      _Response("&&&START&&&" + json.dumps({"ssecurity": SSECURITY})))
        listing = _Flow(_Request("de.hlth.io.mi.com", "/app/v1/source/get_source_list", {"_nonce": nonce}),
                        _Response(encrypted_body(json.dumps(device_list(band())), nonce)))

        # The device list decrypts with the health login even when another login came later.
        printed = self.capture([login, other_login, listing])

        self.assertIn(f"key: {KEY}", printed)

    def test_explains_a_device_list_seen_without_a_login(self) -> None:
        listing = _Flow(_Request("de.hlth.io.mi.com", "/app/v1/source/get_source_list", {"_nonce": "x"}), _Response("x"))

        self.assertIn("log in again", self.capture([listing]))


class _ScriptedWeb:
    """Answers the login requests in order, recording what was asked."""

    def __init__(self, replies: list[Reply]) -> None:
        self._replies = replies
        self.asked: list[str] = []
        self.cookies = {"serviceToken": "token"}

    def request(self, method: str, url: str, **_: object) -> Reply:
        self.asked.append(f"{method} {url.split('?')[0]}")
        return self._replies.pop(0)

    def cookie(self, name: str, prefer_domain: str = "") -> str:
        return self.cookies.get(name, "")


def reply(body: str = "", status: int = 200, **headers: str) -> Reply:
    message = Message()
    for name, value in headers.items():
        message[name.replace("_", "-")] = value
    return Reply(status, message, body.encode())


class LoginTests(unittest.TestCase):
    def login(self, replies: list[Reply], answers: list[str] | None = None) -> tuple[XiaomiLogin, _ScriptedWeb]:
        queue = list(answers or [])
        account = XiaomiLogin("someone@example.com", "secret", ask=lambda _: queue.pop(0))
        web = _ScriptedWeb(replies)
        account._web = web  # noqa: SLF001 - inject the fake transport
        return account, web

    def test_a_trusted_computer_logs_in_with_the_password_alone(self) -> None:
        account, web = self.login([
            reply('&&&START&&&{"_sign":"s","qs":"q","callback":"c"}'),
            reply('&&&START&&&{"ssecurity":"' + SSECURITY + '","location":"https://sts/1"}'),
            reply(status=200),
        ])

        credentials = account.login()

        self.assertEqual(credentials.ssecurity, SSECURITY)
        self.assertEqual(credentials.service_token, "token")
        self.assertEqual(web.asked[:2], ["GET https://account.xiaomi.com/pass/serviceLogin",
                                         "POST https://account.xiaomi.com/pass/serviceLoginAuth2"])

    def test_a_new_computer_confirms_an_emailed_code_and_reads_ssecurity_from_the_redirect(self) -> None:
        account, _ = self.login([
            reply('&&&START&&&{"_sign":"s","qs":"q","callback":"c"}'),
            reply('&&&START&&&{"notificationUrl":"https://account.xiaomi.com/fe?context=ctx"}'),
            reply(),                                   # open the notification page
            reply('{"options":["email"]}'),            # verification methods
            reply('{"code":0}'),                       # code sent
            reply('{"code":0,"location":"https://account.xiaomi.com/next"}'),
            reply(status=302, extension_pragma=json.dumps({"ssecurity": SSECURITY}), Location="https://sts/2"),
            reply(status=200),
        ], answers=["123456"])

        self.assertEqual(account.login().ssecurity, SSECURITY)

    def test_a_wrong_password_is_reported_without_secrets(self) -> None:
        account, _ = self.login([
            reply('&&&START&&&{"_sign":"s","qs":"q","callback":"c"}'),
            reply('&&&START&&&{"code":70016,"desc":"wrong password"}'),
        ])

        with self.assertRaises(LoginError) as raised:
            account.login()
        self.assertNotIn("secret", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
