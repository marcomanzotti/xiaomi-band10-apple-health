"""Band10 → JSON fetcher CLI.

Usage:
  python -m band10.cli login                 # test auth only
  python -m band10.cli probe [--days N]      # discover the sleep endpoint
  python -m band10.cli fetch [--days N] -o out.json

Credentials come from env vars (recommended) or prompts:
  MI_USER      Xiaomi account email/phone
  MI_PASS      Xiaomi account password
  MI_REGION    cloud region subdomain (de/sg/us/ru), default 'de'
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
from datetime import date, timedelta

from loguru import logger

from .health_client import make_client


def _creds() -> tuple[str, str, str]:
    user = os.environ.get("MI_USER") or input("Xiaomi account email/phone: ").strip()
    pw = os.environ.get("MI_PASS") or getpass.getpass("Xiaomi password: ")
    region = os.environ.get("MI_REGION", "de").strip()
    return user, pw, region


def _date_range(days: int) -> tuple[date, date]:
    today = date.today()
    return today - timedelta(days=days), today


def cmd_login(_: argparse.Namespace) -> int:
    user, pw, region = _creds()
    client = make_client(user, pw, region)
    print(f"OK — logged in. user_id={client.session.user_id} region={region}")
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    user, pw, region = _creds()
    client = make_client(user, pw, region)
    d0, d1 = _date_range(args.days)
    report = client.probe_endpoints(d0, d1)

    hits = [k for k, v in report.items() if v.get("ok")]
    print("\n=== PROBE REPORT ===")
    for name, res in report.items():
        mark = "HIT " if res.get("ok") else "miss"
        detail = (
            f"code={res.get('code')} keys={res.get('keys')}"
            if res.get("ok")
            else res.get("error", "")
        )
        print(f"[{mark}] {name}: {res['url']}\n        {detail}")

    if args.dump:
        with open(args.dump, "w") as f:
            json.dump(report, f, indent=2, default=str)
        print(f"\nFull report written to {args.dump}")

    if not hits:
        print(
            "\nNo endpoint responded. Next step: capture Mi Fitness traffic — "
            "see scripts/capture_help.md"
        )
        return 1
    print(f"\nResponded: {hits}. Inspect their 'sample' in the dump to find sleep fields.")
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    user, pw, region = _creds()
    client = make_client(user, pw, region)
    d0, d1 = _date_range(args.days)
    try:
        raw = client.fetch_sleep(d0, d1)
    except NotImplementedError as e:
        logger.error(str(e))
        return 1
    # Parsing into the normalized model happens in parse.py once the schema is known.
    out = args.output
    with open(out, "w") as f:
        json.dump(raw, f, indent=2, default=str)
    print(f"Wrote raw sleep response to {out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="band10")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("login", help="test authentication")
    sp.set_defaults(func=cmd_login)

    sp = sub.add_parser("probe", help="discover the sleep data endpoint")
    sp.add_argument("--days", type=int, default=3)
    sp.add_argument("--dump", default="probe_report.json")
    sp.set_defaults(func=cmd_probe)

    sp = sub.add_parser("fetch", help="fetch sleep data (needs confirmed endpoint)")
    sp.add_argument("--days", type=int, default=7)
    sp.add_argument("-o", "--output", default="sleep_export.json")
    sp.set_defaults(func=cmd_fetch)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
