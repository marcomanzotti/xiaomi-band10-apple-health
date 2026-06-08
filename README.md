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
| iOS HealthKit writer (SwiftUI) | ✅ builds & works; testable now with `sample_sleep.json` |
| Xiaomi login (password flow) | ⚠️ reaches `securityStatus 16` (identity verification) — see below |
| Sleep-data endpoint discovery | 🚧 probe scaffolding ready; endpoint not yet confirmed |

### The Xiaomi auth wall

The modern Mi Account login (vendored from
[huami-token](https://codeberg.org/argrento/huami-token/), MIT) accepts the
password but then returns `securityStatus: 16` with a `notificationUrl` —
Xiaomi's identity-verification step. Accounts created via **Google/Facebook
sign-in have no Xiaomi password**, so you must first set a password at
[account.xiaomi.com](https://account.xiaomi.com) and complete the verification.
Capturing Mi Fitness's real traffic with mitmproxy is the reliable fallback for
discovering the exact sleep endpoint (see `fetcher/scripts/`).

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
export MI_USER="you@example.com" MI_REGION="de"
read -s MI_PASS && export MI_PASS
.venv/bin/python -m band10.cli login      # test auth
.venv/bin/python -m band10.cli probe      # discover sleep endpoint
```

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
