# Band 10 → Apple Health

Talk to a **Xiaomi Smart Band 10 directly over Bluetooth** from an iPhone, with
no Mi Fitness and no Xiaomi cloud in the data path, and write everything the
band records into Apple Health: **steps, active energy, distance, heart rate,
resting heart rate, SpO₂ and sleep stages** (Light / Deep / REM / Awake).

The sync runs on its own in the background, the way the vendor app does: the
phone stays connected to the band, downloads new data on every reconnection
and then about every 15 minutes, and writes it to Health as soon as Health can
be written (it queues while the phone is locked).

## How it works

```
Band 10 ──BLE (FE95, encrypted)──▶ Band10Sync (iOS) ──▶ disk queue ──▶ Apple Health
```

- **`ios/Band10Kit/`** — Swift package.
  - `Band10Kit`: the band protocol with no platform code — frame codec, CRC,
    session keys (HKDF), AES-CTR/CCM, protobuf messages, pairing and
    authentication, the activity-file download sequence, and parsers for the
    band's files (per-minute activity, daily summary, sleep, sleep stages,
    spot measurements). Fully unit-tested.
  - `Band10Sync`: what an app embeds — CoreBluetooth link with state
    restoration, the sync engine, an on-disk queue, the HealthKit writer
    (deduplicated through sync identifiers) and a SwiftUI settings screen.
- **`ios/Band10Health/`** — a test app used to probe the band. It never writes
  to Health. The real sync is meant to live in your own app (the author uses
  it inside FitTracker).
- **`fetcher/`** — Python tools for the one step that still needs Xiaomi (see
  below).

## The one step that needs Xiaomi

Every session with the band is authenticated with a 16-byte key created when
the band is paired. The Band 10 only accepts *server-assisted* pairing, so the
key is created by Xiaomi's servers once per pairing:

1. Pair the band with Mi Fitness once.
2. Fetch the key from your account with `fetcher/scripts/fetch_band_key.py`
   (it replays Mi Fitness's device-list call; capture how-to in
   `fetcher/scripts/capture_help.md`). The key is written to a file readable
   only by you and is never printed.
3. Give the key to the app (settings screen, or launch argument
   `--band-set-authkey` from a Mac). It is kept in the Keychain, on that phone
   only.
4. Close Mi Fitness for good (or delete it): two apps cannot share the band's
   session.

After that, nothing goes to Xiaomi. Pairing the band again changes the key.

## Status

| Part | State |
|------|-------|
| Transport, encryption, authentication | ✅ verified on a real band |
| Key retrieval from the Xiaomi account | ✅ |
| Activity download + file parsers | ✅ unit-tested against the Gadgetbridge layouts; first run on a real band pending |
| HealthKit writer, background sync | ✅ builds; first run on a real band pending |
| Workouts | ❌ left on the band for now |
| Weather, notifications, alarms on the band | ❌ not served |

Running tests (outside an iCloud-synced folder for the build products):

```bash
cd ios/Band10Kit
swift test --scratch-path ~/.cache/band10kit-build
```

### Lessons learned

- Introduce the phone as **iOS** in the authentication step. Declaring an
  Android phone over Bluetooth LE made the band stop listening on LE and drop
  off until a factory reset (Android phones use Bluetooth Classic with it).
  AstroBox does the same: iOS over LE, Android over Classic.
- A bound band silently drops any unauthenticated request.

## Legal & disclaimer

Personal-use tool for **your own** band, **your own** account and **your own**
health data. Unofficial; not affiliated with or endorsed by Xiaomi or Apple.
Use at your own risk.

## Credits

- Band protocol and file layouts: [Gadgetbridge](https://gadgetbridge.org) (AGPL-3.0).
- Companion-device field names and the iOS-over-LE convention: [AstroBox](https://github.com/AstralSightStudios) (AGPL-3.0).
- Pairing protocol: static analysis of Mi Fitness with [REA](https://github.com/morluto/rea).
- Xiaomi account login + RC4 crypto: [huami-token](https://codeberg.org/argrento/huami-token/) by Kirill Snezhko (MIT).

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE). Copyright (c) 2026 Marco Manzotti.

The project was MIT-licensed up to commit `d41bc7c`. It moved to the AGPL so the
band protocol code can build on Gadgetbridge, which is AGPL-3.0. The vendored
huami-token code under `fetcher/band10/vendor_huami/` keeps its own MIT notice.
