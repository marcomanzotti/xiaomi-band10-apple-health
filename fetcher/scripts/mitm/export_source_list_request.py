"""mitmdump addon for offline use (-n -r): exports what is needed to replay the
device-list call (`/app/v1/source/get_source_list`) from a recorded Mi Fitness session.

Writes a JSON file named by BAND_EXPORT_OUT (keep it in the git-ignored capture folder:
it contains live session tokens). Prints only non-secret facts."""
import base64
import hashlib
import json
import os
import re
import urllib.parse

OUT_PATH = os.environ["BAND_EXPORT_OUT"]
TARGET = "/app/v1/source/get_source_list"
SSECURITY_PATTERN = re.compile(r'"ssecurity"\s*:\s*"([^"]+)"')


class RC4:
    def __init__(self, key: bytes) -> None:
        self.state = list(range(256))
        j = 0
        for i in range(256):
            j = (j + self.state[i] + key[i % len(key)]) & 0xFF
            self.state[i], self.state[j] = self.state[j], self.state[i]
        self.i = 0
        self.j = 0

    def crypt(self, data: bytes) -> bytes:
        out = bytearray(len(data))
        state = self.state
        for index, byte in enumerate(data):
            self.i = (self.i + 1) & 0xFF
            self.j = (self.j + state[self.i]) & 0xFF
            state[self.i], state[self.j] = state[self.j], state[self.i]
            out[index] = byte ^ state[(state[self.i] + state[self.j]) & 0xFF]
        return bytes(out)


def rc4_key(ssecurity: str, nonce: str) -> bytes:
    return hashlib.sha256(base64.b64decode(ssecurity) + base64.b64decode(nonce)).digest()


def make_cipher(key: bytes) -> RC4:
    cipher = RC4(key)
    cipher.crypt(b"\x00" * 1024)
    return cipher


class SourceListRequestExport:
    def __init__(self) -> None:
        self.secrets = []
        self.target = None

    def response(self, flow) -> None:
        blob = (flow.response.get_text(strict=False) or "") + "\n" + flow.response.headers.get("extension-pragma", "")
        for match in SSECURITY_PATTERN.findall(blob):
            value = match.replace("\\/", "/")
            if value not in self.secrets:
                self.secrets.append(value)
        if flow.request.path.split("?")[0].endswith(TARGET):
            self.target = flow  # keep the most recent one

    def done(self) -> None:
        if self.target is None:
            print("NO get_source_list call in capture")
            return
        request = self.target.request
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(request.path).query, keep_blank_values=True))
        form = dict(urllib.parse.parse_qsl(request.get_text(strict=False) or "", keep_blank_values=True))
        params = {**query, **form}
        nonce = params["_nonce"]
        body = (self.target.response.get_text(strict=False) or "").strip()
        working = None
        for secret in self.secrets:
            key = rc4_key(secret, nonce)
            try:
                json.loads(make_cipher(key).crypt(base64.b64decode(body)).decode("utf-8"))
            except Exception:
                continue
            working = secret
            break
        if working is None:
            print("no captured ssecurity decrypts the device list")
            return
        cipher = make_cipher(rc4_key(working, nonce))
        encrypted_keys = sorted(k for k in params if k not in ("signature", "_nonce", "ssecurity"))
        plain = {k: cipher.crypt(base64.b64decode(params[k])).decode("utf-8") for k in encrypted_keys}
        export = {
            "method": request.method,
            "scheme": request.scheme,
            "host": request.pretty_host,
            "path": request.path.split("?")[0],
            "params_in_query": sorted(query),
            "params_in_form": sorted(form),
            "plain_params": plain,
            "captured_signature": params.get("signature"),
            "captured_nonce": nonce,
            "ssecurity": working,
            "headers": [[k, v] for k, v in request.headers.items(multi=True)],
        }
        with open(OUT_PATH, "w", encoding="utf-8") as handle:
            json.dump(export, handle)
        os.chmod(OUT_PATH, 0o600)
        header_names = sorted({k.lower() for k, _ in export["headers"]})
        cookie_names = sorted(c.split("=")[0].strip() for k, v in export["headers"] if k.lower() == "cookie" for c in v.split(";"))
        print("EXPORTED", request.method, request.pretty_host + export["path"])
        print("query params:", export["params_in_query"], "form params:", export["params_in_form"])
        print("plain param names:", sorted(plain), "data:", plain.get("data"))
        print("header names:", header_names)
        print("cookie names:", cookie_names)


addons = [SourceListRequestExport()]
