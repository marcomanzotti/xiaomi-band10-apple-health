# Band 10 → Apple Health

Inject **detailed, segmented sleep data** from a Xiaomi Smart Band 10 (Mi Fitness)
into Apple Health — sleep **stages** (Light / Deep / REM / Awake), **heart rate**,
**SpO₂**, **HRV (SDNN)** and **respiratory rate**.

## Why

Mi Fitness on iOS writes sleep to Apple Health as a *single* undifferentiated
`Asleep` block, even though the app itself records full sleep stages and vitals.
This project recovers the detail and writes proper, segmented HealthKit samples.

## How it works

Two halves connected by a small JSON contract
(see [`fetcher/band10/sleep_model.py`](fetcher/band10/sleep_model.py)):

```
Xiaomi cloud ──(fetcher, Python)──▶ sleep_export.json ──(iOS app)──▶ Apple Health
```

1. **`fetcher/`** — Python tool that logs into the Xiaomi Mi Account
   (`miothealth` service), talks to the `*.hlth.io.mi.com` health cloud, and
   exports your sleep data to the normalized JSON format.
2. **`ios/`** — a SwiftUI app you run on your iPhone. It opens the JSON, asks
   for HealthKit permission, and writes one `HKCategorySample` per sleep stage
   (`.asleepCore/.asleepDeep/.asleepREM/.awake/.inBed`) plus quantity samples
   for HR / SpO₂ / HRV / respiratory rate.

## Status

| Part | State |
|------|-------|
| iOS HealthKit writer (SwiftUI) | ✅ builds & runs on device; testable now with `sample_sleep.json` |
| Xiaomi cloud endpoint | ✅ **confirmed via live capture** (see below) |
| Xiaomi login | ⚠️ `securityStatus 16` (identity verification) — set a Xiaomi password |
| Decrypt + replicate sleep request | 🚧 next: get `ssecurity` from login, then `decrypt_capture.py` |

### What the traffic capture revealed

A live mitmproxy capture of **Mi Fitness 3.49.0 (iOS)** syncing the Band 10
(region `de`) showed — with **no certificate pinning**:

- Health data lives on the **regional** host `de.hlth.io.mi.com`.
- Sleep + vitals come from
  `POST /app/v1/data/get_fitness_data_by_watermark`.
- Auth is a **`serviceToken` cookie**; the request `data` field and the
  response body are **RC4-encrypted** (key = `ssecurity` + per-request `_nonce`).
- `ssecurity` is **not** in the traffic — it only comes from a full login.

### The Xiaomi auth wall

The modern Mi Account login (vendored from
[huami-token](https://codeberg.org/argrento/huami-token/), MIT) accepts the
password but returns `securityStatus: 16` with a `notificationUrl` — Xiaomi's
identity-verification step. Accounts that sign in via **Google/Facebook have no
Xiaomi password**, so set one at [account.xiaomi.com](https://account.xiaomi.com)
(you can keep using Google in the app). Once login succeeds you get `ssecurity`;
then `fetcher/decrypt_capture.py` decrypts the captured flows to reveal the exact
`data` payload to replicate, which gets pinned in
`health_client.WORKING_ENDPOINTS`.

## Quick start (iOS, with sample data — no Xiaomi needed)

```bash
open ios/Band10Health/Band10Health.xcodeproj
```

1. Select your iPhone as the run target, set your signing Team, run (⌘R).
2. In the app: **Richiedi accesso ad Apple Health** → enable the toggles.
3. AirDrop / put `sample_sleep.json` in Files, then **Scegli file JSON…**.
4. **Importa in Salute** → open Apple Health → Sleep to see the staged night.

## Quick start (fetcher)

```bash
cd fetcher
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export MI_USER="you@example.com" MI_REGION="de"   # de = Europe (confirmed)
read -s MI_PASS && export MI_PASS
.venv/bin/python -m band10.cli login      # test auth (needs a Xiaomi password)
.venv/bin/python -m band10.cli probe      # hit the confirmed endpoints
# Once logged in, reveal the real request payload from a capture:
.venv/bin/python decrypt_capture.py capture/mifitness_flows.mitm
```

Capturing Mi Fitness traffic (to confirm the payload on your account/region) is
documented in [`fetcher/scripts/capture_help.md`](fetcher/scripts/capture_help.md).

## Legal & disclaimer

Personal-use tool for accessing **your own** account and **your own** health
data via Xiaomi's own endpoints, then writing it into **your own** Apple Health.
Unofficial; not affiliated with or endorsed by Xiaomi/Huami/Apple. The Xiaomi
API is undocumented and may change or break at any time. Use at your own risk.

## Credits

- Xiaomi Mi Account login + RC4 crypto: [huami-token](https://codeberg.org/argrento/huami-token/) by Kirill Snezhko (MIT).
- Sleep-data schema research: [Gadgetbridge](https://gadgetbridge.org), [hacking-mifit-api](https://github.com/micw/hacking-mifit-api), [zepp_to_influxdb](https://github.com/bentasker/zepp_to_influxdb).

## License

MIT — see [LICENSE](LICENSE).
