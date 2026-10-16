"""`python3 get_band_key.py`: prints the auth key of every band on a Xiaomi account."""

from __future__ import annotations

import argparse
import getpass
import os
import sys
from pathlib import Path

from .account import LoginError, XiaomiLogin
from .devices import REGIONS, CloudError, Wearable, list_wearables

_KEY_FILE_MODE = 0o600


def _print(wearables: list[Wearable]) -> None:
    for band in wearables:
        print(f"\n  {band.name}  ({band.model}, MAC {band.mac}, region {band.region})")
        print(f"  key: {band.key}")


def _save(wearables: list[Wearable], path: Path) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, _KEY_FILE_MODE)
    # The mode above applies only to a new file: an existing one keeps its own.
    os.fchmod(descriptor, _KEY_FILE_MODE)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.writelines(f"{band.mac} {band.key} {band.name}\n" for band in wearables)
    print(f"\nSaved to {path} (readable only by you).")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Get the Bluetooth auth key of your Xiaomi band from your own Xiaomi account."
    )
    parser.add_argument("--region", choices=REGIONS, help="skip the search and ask only this region")
    parser.add_argument("--save", type=Path, metavar="FILE", help="also write the keys to FILE (mode 600)")
    args = parser.parse_args(argv)

    print("Log in with the Xiaomi account your band is paired to (in Mi Fitness).")
    print("Nothing is stored; the password goes only to account.xiaomi.com.\n")
    username = input("Email, phone number or Xiaomi ID: ").strip()
    password = getpass.getpass("Password (not shown): ")
    try:
        credentials = XiaomiLogin(username, password).login()
    except LoginError as error:
        print(f"\nLogin failed: {error}")
        return 1

    print("\nLogged in. Looking for your bands…")
    found: list[Wearable] = []
    problems: list[str] = []
    for region in [args.region] if args.region else REGIONS:
        try:
            found.extend(list_wearables(credentials.service_token, credentials.ssecurity, region))
        except CloudError as error:
            problems.append(str(error))
        if found:
            break

    if not found:
        print("\nNo band with a key was found on this account.")
        print("Pair the band with Mi Fitness first, then run this again.")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print("\nKeep this key private: anyone with it can read your band.")
    _print(found)
    if args.save:
        _save(found, args.save)
    print("\nPairing the band again in Mi Fitness creates a new key.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
