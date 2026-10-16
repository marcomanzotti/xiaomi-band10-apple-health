# iPhone: Band Sync

Band Sync is a small app that does one thing: keep the band connected and
copy what it records into Apple Health, in the background.

## What you need

- A Mac with **Xcode** (free, App Store). Open it once after installing.
- Your **Apple ID** added to Xcode: Xcode → Settings → Accounts → **+** →
  Apple ID. A free Apple ID is enough.
- The iPhone, a cable, and the **band key** ([how to get it](get-the-key.md)).
- iOS 16 or later.

## Install

1. Connect the iPhone with the cable, unlock it and tap **Trust** if asked.
2. On the iPhone enable **Developer Mode**: Settings → Privacy & Security →
   Developer Mode → on (the phone restarts). It only appears after the iPhone
   has been connected to Xcode once; if it is missing, run step 3 once and
   come back.
3. On the Mac, from the repository folder:

   ```sh
   ios/install.sh --key band.key
   ```

   The first run finds your Apple team, builds the app (a few minutes) and
   installs it.
4. The first time, iOS blocks apps from a new developer. On the iPhone:
   Settings → General → **VPN & Device Management** → your Apple ID →
   **Trust**. Then run step 3 again so the key reaches the app (or paste it,
   see below).
5. Open **Band Sync**:
   - allow **Bluetooth**;
   - tap **Allow writing to Health**, then **Turn On All** → **Allow**.

Within a minute the status shows **connected** and the first sync starts.

### Entering the key by hand

Instead of `--key`: copy the key on the Mac (on an iPhone signed in to the same
Apple ID, Universal Clipboard brings it over), then in Band Sync → **Band key**
→ **Paste** → **Save key**.

### Without the script

Open `ios/Band10Health/Band10Health.xcodeproj` in Xcode, select the
**Band10Health** target → Signing & Capabilities → your team, choose your
iPhone as destination and press Run.

## Every 7 days

Apps signed with a free Apple ID stop opening after 7 days. Connect the
iPhone and run `ios/install.sh` again: the key and the data stay on the phone.
A paid Apple Developer account (99 USD/year) signs for a year instead.

## Daily use

Nothing to do. The app:

- reconnects whenever the band is back in range, even if you never open it;
- downloads new data on every connection and then about every 15 minutes;
- keeps the files on the phone until Health accepts them (Health cannot be
  written while the phone is locked), then writes them;
- sets the band's clock, including daylight-saving changes.

Do not swipe the app away in the app switcher: iOS then stops waking it for
Bluetooth until you open it again.

Apple Watch and the band can be used on the same day. Each writes to Health
under its own source, and Health counts overlapping steps only once.

## Building it into your own app

`ios/Band10Kit` is a Swift package. Add it to your Xcode project, link the
`Band10Sync` library, and:

```swift
import Band10Sync

let engine = BandSyncEngine(configuration: .init(
    restoreIdentifier: "com.example.myapp.band",
    keychainService: "com.example.myapp.band"
))
engine.start()                       // at launch, not in a view
// …and show BandSyncView(engine: engine) somewhere in your settings.
```

Your app needs the HealthKit capability, the `bluetooth-central` background
mode and the `NSBluetoothAlwaysUsageDescription`,
`NSHealthUpdateUsageDescription` and `NSHealthShareUsageDescription` texts.
