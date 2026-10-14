"""mitmdump addon for offline use (-n -r): decrypts Xiaomi cloud calls recorded in a capture.

Prints only structure (endpoint, JSON key names, value lengths). Full plaintext goes to the
file named by BAND_DECRYPT_OUT, which must live in the git-ignored capture folder."""
import base64
import hashlib
import json
import os
import re
import urllib.parse

OUT_PATH = os.environ["BAND_DECRYPT_OUT"]
SENSITIVE = re.compile(r"key|token|secret|sign|ssecurity|passw|nonce|random|share", re.IGNORECASE)
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


def make_cipher(ssecurity: str, nonce: str) -> RC4:
    key = hashlib.sha256(base64.b64decode(ssecurity) + base64.b64decode(nonce)).digest()
    cipher = RC4(key)
    cipher.crypt(b"\x00" * 1024)
    return cipher


def shape(value, depth: int = 0):
    """Key names and value sizes only."""
    if isinstance(value, dict):
        return {k: (f"<{len(str(v))} chars>" if SENSITIVE.search(k) and not isinstance(v, (dict, list)) else shape(v, depth + 1))
                for k, v in value.items()}
    if isinstance(value, list):
        return [shape(value[0], depth + 1), f"...x{len(value)}"] if value else []
    if isinstance(value, str):
        return f"str[{len(value)}]"
    return type(value).__name__


class Decrypt:
    def __init__(self) -> None:
        self.flows = []
        self.secrets = []

    def response(self, flow) -> None:
        self.flows.append(flow)
        blob = (flow.response.get_text(strict=False) or "") + "\n" + flow.response.headers.get("extension-pragma", "")
        for match in SSECURITY_PATTERN.findall(blob):
            value = match.replace("\\/", "/")
            if value not in self.secrets:
                self.secrets.append(value)
                print(f"SSECURITY candidate #{len(self.secrets)} from {flow.request.pretty_host}{flow.request.path.split('?')[0]} (len {len(value)})")

    def done(self) -> None:
        results = []
        for flow in self.flows:
            request = flow.request
            params = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(request.path).query, keep_blank_values=True))
            params.update(dict(urllib.parse.parse_qsl(request.get_text(strict=False) or "", keep_blank_values=True)))
            nonce = params.get("_nonce")
            if not nonce:
                continue
            endpoint = f"{request.method} {request.pretty_host}{request.path.split('?')[0]}"
            body = (flow.response.get_text(strict=False) or "").strip()
            decoded = None
            for index, secret in enumerate(self.secrets, start=1):
                try:
                    plain = make_cipher(secret, nonce).crypt(base64.b64decode(body)).decode("utf-8")
                    response_json = json.loads(plain)
                except Exception:
                    continue
                try:
                    cipher = make_cipher(secret, nonce)
                    encrypted_keys = sorted(k for k in params if k not in ("signature", "_nonce", "ssecurity"))
                    request_plain = {k: cipher.crypt(base64.b64decode(params[k])).decode("utf-8", "replace") for k in encrypted_keys}
                except Exception as error:
                    request_plain = {"_error": str(error)}
                decoded = {"endpoint": endpoint, "secret": index, "request": request_plain, "response": response_json}
                break
            if decoded is None:
                print(f"UNDECRYPTED {endpoint} status={flow.response.status_code} body_len={len(body)}")
                continue
            results.append(decoded)
            request_data = decoded["request"].get("data", "")
            try:
                request_shape = shape(json.loads(request_data))
            except Exception:
                request_shape = f"str[{len(request_data)}]"
            print(f"OK {endpoint} secret#{decoded['secret']} req={json.dumps(request_shape)[:300]} resp={json.dumps(shape(decoded['response']))[:500]}")
        with open(OUT_PATH, "w", encoding="utf-8") as handle:
            for item in results:
                handle.write(json.dumps(item, ensure_ascii=False) + "\n")
        os.chmod(OUT_PATH, 0o600)
        print(f"DONE decrypted={len(results)} secrets={len(self.secrets)}")


addons = [Decrypt()]
