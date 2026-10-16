#!/bin/zsh
# Builds Band Sync and installs it on the iPhone connected to this Mac.
#
#   ios/install.sh                 build + install
#   ios/install.sh --key band.key  also hand the band key to the app
#   ios/install.sh --build-only    build, do not install
#
# Needs Xcode with your Apple ID added (Xcode → Settings → Accounts). A free
# Apple ID works; apps signed with it must be reinstalled every 7 days: run
# this script again (your data and the key stay on the phone).
set -euo pipefail

here="${0:A:h}"
project="$here/Band10Health/Band10Health.xcodeproj"
signing="$here/Band10Health/Signing.local.xcconfig"
# Build products outside iCloud-synced folders (Desktop/Documents), which break code signing.
derived="$HOME/Library/Developer/Xcode/DerivedData/BandSync-install"
key_file=""
build_only=false

while (( $# )); do
  case "$1" in
    --key) (( $# >= 2 )) || { echo "--key needs a file, e.g. --key band.key" >&2; exit 2; }; key_file="$2"; shift 2 ;;
    --build-only) build_only=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "\n✗ $1" >&2; exit 1; }

command -v xcodebuild >/dev/null || fail "Xcode is not installed. Install it from the App Store, open it once, then run this again."

# 1. Your Apple team, remembered in Signing.local.xcconfig (ignored by git).
if [[ ! -f "$signing" ]]; then
  team=""
  teams=($(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -oE 'teamID = "?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | sort -u))
  if (( ${#teams} == 0 )); then
    teams=($(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
      | awk '/BEGIN/{c=""} {c=c $0 "\n"} /END/{print c | "openssl x509 -noout -subject"; close("openssl x509 -noout -subject")}' \
      | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | sort -u))
  fi
  if (( ${#teams} == 1 )); then
    team="${teams[1]}"
  else
    (( ${#teams} > 1 )) && echo "Apple teams found: ${teams[*]}"
    echo "Your Apple team ID is shown in Xcode → Settings → Accounts → your Apple ID → Team."
    read "team?Apple team ID (10 characters): " || true
  fi
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "\"$team\" is not a team ID."
  bundle="band10health.${team:l}"
  print "DEVELOPMENT_TEAM = $team\nPRODUCT_BUNDLE_IDENTIFIER = $bundle" > "$signing"
  echo "Signing with team $team, app id $bundle (saved in ${signing:t})."
fi
bundle=$(awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER/{print $2}' "$signing")

# 2. The iPhone.
device=""
if ! $build_only; then
  devices=($(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /(available|connected)/ && !/unavailable/ && !/simulated/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$|^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) print $i}'))
  (( ${#devices} > 0 )) || fail "No iPhone found. Connect it with a cable, unlock it, tap \"Trust\", and enable Developer Mode (Settings → Privacy & Security → Developer Mode)."
  device="${devices[1]}"
  (( ${#devices} > 1 )) && echo "Several iPhones found, using $device."
fi

# 3. Build.
echo "\nBuilding Band Sync… (the first build takes a few minutes)"
destination=$([[ -n "$device" ]] && echo "id=$device" || echo "generic/platform=iOS")
mkdir -p "$derived"
xattr -cr "$derived" 2>/dev/null || true
xcodebuild -project "$project" -scheme Band10Health -configuration Release \
  -destination "$destination" -derivedDataPath "$derived" -allowProvisioningUpdates -quiet build \
  || fail "The build failed. Open $project in Xcode once, select your team under Signing & Capabilities, then run this again."
app="$derived/Build/Products/Release-iphoneos/Band10Health.app"
$build_only && { echo "\n✓ Built $app"; exit 0; }

# 4. Install, and hand over the key.
echo "Installing on the iPhone…"
xcrun devicectl device install app --device "$device" "$app" >/dev/null || fail "Installation failed. Is the iPhone unlocked?"
if [[ -n "$key_file" ]]; then
  [[ -r "$key_file" ]] || fail "Cannot read $key_file."
  key=$(grep -oE '[0-9a-fA-F]{32}' "$key_file" | head -1 || true)
  [[ -n "$key" ]] || fail "No 32-digit key in $key_file."
  # The key is a launch argument: visible to other users of this Mac for a moment.
  if xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle" -- --band-set-authkey "$key" >/dev/null 2>&1; then
    echo "Key handed to the app."
  else
    echo "\nThe app could not be opened from the Mac. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → Trust."
    echo "Then run: ios/install.sh --key $key_file   (or paste the key in the app)."
  fi
fi
echo "\n✓ Done. Open Band Sync on the iPhone, allow Bluetooth and \"Turn On All\" for Health."
echo "  Reinstall every 7 days with the same command (free Apple ID limit)."
