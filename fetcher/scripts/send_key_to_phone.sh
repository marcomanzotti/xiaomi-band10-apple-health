#!/bin/zsh
# Fetch the band's current auth key from the Xiaomi account and hand it to an app
# on the iPhone, which stores it in its Keychain and starts syncing.
#
# Usage: send_key_to_phone.sh [bundle-id] [device-udid]
#   bundle-id   default com.marco.manzotti.fittracker
#   device-udid default the author's iPhone
#
# The key is never printed. It travels as a launch argument over the USB/Wi-Fi
# link to the phone, so it is visible only to this Mac's process list while
# devicectl runs.
set -euo pipefail

bundle="${1:-com.marco.manzotti.fittracker}"
device="${2:-00008110-000425CC1A85401E}"
root="${0:A:h:h:h}"
capture="$root/fetcher/capture"

python3 "$root/fetcher/scripts/fetch_band_key.py" "$capture/source_list_request.json" "$capture/band_authkey.hex"

key="$(tr -d '[:space:]' < "$capture/band_authkey.hex")"
if [[ ! "$key" =~ ^[0-9a-fA-F]{32}$ ]]; then
  echo "FAILED: the stored key is not 32 hexadecimal digits" >&2
  exit 1
fi

xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" \
  -- --band-set-authkey "$key" > /dev/null
echo "OK key handed to $bundle on $device"
