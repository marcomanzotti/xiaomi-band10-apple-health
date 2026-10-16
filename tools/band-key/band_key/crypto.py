"""Request encryption used by the Xiaomi health cloud (Mi Fitness).

Scheme: RC4 with the first 1024 bytes of keystream dropped. The key for each
request is SHA-256(ssecurity || nonce), where `ssecurity` comes from the login
and the nonce is fresh per request. Parameters are signed with SHA-1.

Derived from huami-token by Kirill Snezhko (MIT), see THIRD_PARTY_NOTICES.md.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import struct
import time

_DROPPED_KEYSTREAM = 1024
_NONCE_RANDOM_BYTES = 8
_MILLISECONDS_PER_MINUTE = 60_000


class _RC4:
    def __init__(self, key: bytes) -> None:
        self._s = list(range(256))
        j = 0
        for i in range(256):
            j = (j + self._s[i] + key[i % len(key)]) & 0xFF
            self._s[i], self._s[j] = self._s[j], self._s[i]
        self._i = 0
        self._j = 0

    def crypt(self, data: bytes) -> bytes:
        out = bytearray(len(data))
        for index, byte in enumerate(data):
            self._i = (self._i + 1) & 0xFF
            self._j = (self._j + self._s[self._i]) & 0xFF
            self._s[self._i], self._s[self._j] = self._s[self._j], self._s[self._i]
            out[index] = byte ^ self._s[(self._s[self._i] + self._s[self._j]) & 0xFF]
        return bytes(out)


def _cipher(key_b64: str) -> _RC4:
    cipher = _RC4(base64.b64decode(key_b64))
    cipher.crypt(bytes(_DROPPED_KEYSTREAM))
    return cipher


def request_key(ssecurity_b64: str, nonce_b64: str) -> str:
    """The per-request RC4 key: base64(SHA-256(ssecurity || nonce))."""
    combined = base64.b64decode(ssecurity_b64) + base64.b64decode(nonce_b64)
    return base64.b64encode(hashlib.sha256(combined).digest()).decode()


def new_nonce() -> str:
    """base64(8 random bytes || big-endian int32 of the current minute)."""
    minute = int(time.time() * 1000) // _MILLISECONDS_PER_MINUTE
    return base64.b64encode(secrets.token_bytes(_NONCE_RANDOM_BYTES) + struct.pack(">i", minute)).decode()


def _sha1_signature(method: str, path: str, params: dict[str, str], key_b64: str) -> str:
    parts = [method.upper(), path] + [f"{name}={params[name]}" for name in sorted(params)] + [key_b64]
    return base64.b64encode(hashlib.sha1("&".join(parts).encode()).digest()).decode()


def encrypt_params(method: str, path: str, params: dict[str, str], nonce_b64: str, ssecurity_b64: str) -> dict[str, str]:
    """Signs, encrypts and signs again the form parameters of a request."""
    key = request_key(ssecurity_b64, nonce_b64)
    signed = dict(params)
    signed["rc4_hash__"] = _sha1_signature(method, path, params, key)
    cipher = _cipher(key)
    encrypted = {name: base64.b64encode(cipher.crypt(signed[name].encode())).decode() for name in sorted(signed)}
    return {**encrypted, "signature": _sha1_signature(method, path, encrypted, key), "_nonce": nonce_b64}


def decrypt_params(encrypted: dict[str, str], nonce_b64: str, ssecurity_b64: str) -> dict[str, str]:
    """Inverse of `encrypt_params`, used by the capture method and the tests."""
    cipher = _cipher(request_key(ssecurity_b64, nonce_b64))
    return {
        name: cipher.crypt(base64.b64decode(encrypted[name])).decode()
        for name in sorted(encrypted)
        if name not in ("signature", "_nonce")
    }


def decrypt_response(body_b64: str, nonce_b64: str, ssecurity_b64: str) -> str:
    """Decrypts a response body; the nonce is the one sent with the request."""
    return _cipher(request_key(ssecurity_b64, nonce_b64)).crypt(base64.b64decode(body_b64)).decode()
