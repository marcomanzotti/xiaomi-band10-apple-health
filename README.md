# Xiaomi Band → Apple Health, without Mi Fitness

Keep the data of your Xiaomi Smart Band for yourself. This project talks to
the band **directly over Bluetooth** and writes what it records into
**Apple Health** (or, on Android, **Health Connect**), with no Xiaomi app and
no Xiaomi cloud in the data path.

| What the band records | Where it goes |
|---|---|
| Steps, active energy, walking distance | Apple Health, minute by minute |
| Heart rate, resting heart rate | Apple Health |
| Blood oxygen (SpO₂), including spot checks | Apple Health |
| Sleep (asleep / awake, and stages when the band computes them) | Apple Health |

On the iPhone the sync runs by itself in the background, the way the vendor
app does: the phone stays connected, downloads new data every time the band
comes back into range and then about every 15 minutes, and writes it to
Health as soon as Health can be written.

> **Status:** verified on a **Xiaomi Smart Band 10**. Other recent Xiaomi
> bands and watches use the same protocol family and *may* work, but have not
> been tested — see [supported devices](docs/supported-devices.md) and please
> report what happens with yours.

## Quick start

You need the band's **auth key**: a 32-digit code created when the band is
paired. The Band 10 can only be paired through Xiaomi's servers, so Xiaomi
creates the key once; after that, nothing goes to Xiaomi.

**1. Pair the band with Mi Fitness once** (the official app, on any phone).

**2. Get the key** — on a Mac or PC with Python 3 (preinstalled on macOS):

```sh
git clone https://github.com/marcomanzotti/xiaomi-band10-apple-health.git
cd xiaomi-band10-apple-health
python3 tools/band-key/get_band_key.py --save band.key
```

Log in with your Xiaomi account (and the code Xiaomi emails you). The key is
printed and saved to `band.key`, readable only by you.
More options: [getting the key](docs/get-the-key.md).

**3a. iPhone** — on a Mac with Xcode and your Apple ID added in Xcode, plug in
the iPhone and run:

```sh
ios/install.sh --key band.key
```

Open **Band Sync** on the iPhone, allow Bluetooth, tap *Allow writing to
Health* → *Turn On All*. Details and the 7-day reinstall: [iPhone guide](docs/iphone.md).

**3b. Android** — use [Gadgetbridge](https://gadgetbridge.org) with the same
key and turn on its Health Connect integration: [Android guide](docs/android.md).

**4. Delete Mi Fitness** from the phone. The band stays paired and the key
keeps working; two apps cannot share the band.

## What is in this repository

| Path | What it is |
|---|---|
| [`tools/band-key/`](tools/band-key) | Gets the band key from your own Xiaomi account. Standard-library Python, no install. Also a mitmproxy add-on as a fallback. |
| [`ios/Band10Kit/`](ios/Band10Kit) | Swift package. `Band10Kit`: the band protocol and file formats, no platform code, 200+ tests. `Band10Sync`: Bluetooth link, background sync engine, Health writer and settings screen, ready to embed in any iOS app. |
| [`ios/Band10Health/`](ios/Band10Health) | **Band Sync**, a minimal iPhone app built on `Band10Sync`. |
| [`ios/install.sh`](ios/install.sh) | Builds and installs Band Sync on a connected iPhone. |
| [`docs/`](docs) | Guides, and [how it works](docs/how-it-works.md): the full protocol, from Bluetooth frames to sleep files. |

## Privacy

- The key and your data stay on your devices. The key tool talks only to
  `account.xiaomi.com` (to log in) and to the Xiaomi health server of your
  region (to read the device list), exactly like Mi Fitness does, and stores
  nothing unless you pass `--save`.
- The iPhone app keeps the key in the Keychain of that phone only, and the
  downloaded files in its own sandbox until they are in Health.
- Anyone with your key can read your band: keep `band.key` private and never
  commit it (it is ignored by git here).

## Limits

- **iPhone:** an app is required (only apps can write to Health). With a free
  Apple ID it must be reinstalled every 7 days; a paid developer account
  removes that.
- **Workouts** recorded on the band are not imported yet; they stay on the band.
- **HRV** is not available from the band on the files seen so far.
- Weather, notifications and alarms on the band are not served.
- Pairing the band again creates a new key: run the key tool again.

## Thanks

Built on the work of [Gadgetbridge](https://gadgetbridge.org) (protocol and file
layouts), [AstroBox](https://github.com/AstralSightStudios) (iOS companion
convention), [huami-token](https://codeberg.org/argrento/huami-token/) (Xiaomi
cloud crypto) and [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor)
(login verification). See [third-party notices](THIRD_PARTY_NOTICES.md).

Not affiliated with or endorsed by Xiaomi or Apple. For your own band, your
own account and your own data. Use at your own risk.

## License

[AGPL-3.0-or-later](LICENSE), because the protocol code builds on Gadgetbridge
(AGPL-3.0). The tools under `tools/band-key/` include MIT-licensed code, see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
