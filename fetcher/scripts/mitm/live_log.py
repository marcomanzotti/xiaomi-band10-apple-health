"""mitmdump addon: append one line per event to a file, flushed immediately.
Only hostnames, paths and sizes are written; never headers, cookies or bodies."""
import os
import time

LOG_PATH = os.environ["BAND_LIVE_LOG"]


def emit(kind: str, detail: str) -> None:
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(f"{time.strftime('%H:%M:%S')} {kind} {detail}\n")


class LiveLog:
    def tls_failed_client(self, data):
        sni = data.conn.sni or "?"
        emit("TLS_CLIENT_FAILED", f"{sni} {data.conn.error or ''}")

    def tls_failed_server(self, data):
        emit("TLS_SERVER_FAILED", f"{data.conn.sni or data.conn.address} {data.conn.error or ''}")

    def tls_established_client(self, data):
        emit("TLS_OK", data.conn.sni or "?")

    def response(self, flow):
        request = flow.request
        emit("FLOW", f"{request.method} {request.pretty_host}{request.path.split('?')[0]} {flow.response.status_code} {len(flow.response.raw_content or b'')}")

    def error(self, flow):
        emit("FLOW_ERROR", f"{flow.request.pretty_host} {flow.error}")


addons = [LiveLog()]
