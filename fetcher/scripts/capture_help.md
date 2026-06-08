# Capturing Mi Fitness traffic (finding the real sleep endpoint)

When endpoint *probing* fails, capture what the Mi Fitness app actually sends.

## Setup (mitmproxy on macOS)

```bash
brew install mitmproxy
mitmweb            # opens a web UI on http://127.0.0.1:8081, proxy on :8080
```

1. On the iPhone (same Wi-Fi): Settings → Wi-Fi → (i) → Configure Proxy →
   Manual → server = your Mac's IP, port = 8080.
2. In Safari on the iPhone, open `http://mitm.it` and install + **trust** the
   mitmproxy CA cert (Settings → General → About → Certificate Trust Settings).
3. Open Mi Fitness and pull-to-refresh / open the sleep detail screen.
4. In the mitmweb UI, filter for `hlth.io.mi.com`. Watch the requests:
   - note the **path** (e.g. `/healthapp/...`),
   - the **method**,
   - the query params (they'll be RC4-encrypted — that's expected).

## Decrypting captured requests

The params are RC4-encrypted with a key derived from `ssecurity` + `_nonce`
(see `band10/vendor_huami/mi_crypto.py`). Once logged in via our client you
have `ssecurity`; pair it with the captured `_nonce` and use
`mi_decrypt_params()` / `mi_decrypt_response()` to read the plaintext and the
response body. That reveals the exact `data` JSON shape to replicate.

## Cert pinning

If Mi Fitness uses certificate pinning you'll see TLS errors and no decrypted
traffic. Workarounds (require a jailbroken device or a patched app) are out of
scope here; prefer probing + the decrypt helpers above first.

## Pinning the result

Once confirmed, fill `WORKING_ENDPOINTS["sleep"]` in `band10/health_client.py`
with the path, method, path_prefix and a `params_builder`, then `band10 fetch`
will work.
