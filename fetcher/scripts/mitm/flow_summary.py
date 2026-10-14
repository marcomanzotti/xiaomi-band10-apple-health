"""mitmdump addon: one summary line per recorded flow, never printing secret values."""
import re

MARKERS = ("ssecurity", "serviceToken", "bindKey", "deviceKey", "encrypt_key", "encryptKey", "auth_key", "authKey")


class Summary:
    def response(self, flow):
        request, response = flow.request, flow.response
        text = ""
        try:
            text = response.get_text(strict=False) or ""
        except Exception:
            pass
        haystack = "\n".join([
            text,
            "\n".join(f"{k}: {v}" for k, v in response.headers.items(multi=True)),
            "\n".join(f"{k}: {v}" for k, v in request.headers.items(multi=True)),
            request.get_text(strict=False) or "",
        ])
        found = [m for m in MARKERS if re.search(m, haystack)]
        path = request.path.split("?")[0]
        print(f"FLOW {request.method} {request.pretty_host}{path} -> {response.status_code} len={len(response.raw_content or b'')} markers={','.join(found) or '-'}")


addons = [Summary()]
