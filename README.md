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
   (once the data-endpoint schema is cracked — see Status) exports sleep data
   to the normalized JSON format.
2. **`ios/`** — a SwiftUI app you run on your iPhone. It opens the JSON, asks
   for HealthKit permission, and writes one `HKCategorySample` per sleep stage
   (`.asleepCore/.asleepDeep/.asleepREM/.awake/.inBed`) plus quantity samples
   for HR / SpO₂ / HRV / respiratory rate.

## Status

| Part | State |
|------|-------|
| iOS HealthKit writer (SwiftUI) | ✅ builds & runs on device; **fully working** with `sample_sleep.json` |
| Xiaomi login (incl. email 2FA / `securityStatus 16`) | ✅ **solved** — see below |
| Session persistence (no repeated email codes) | ✅ solved — cached to `fetcher/.mi_session.json` |
| Sleep data endpoint — discovery | ✅ confirmed: `POST /app/v1/data/get_fitness_data_by_watermark` on `{region}.hlth.io.mi.com` |
| Sleep data endpoint — **request payload schema** | ❌ **unsolved** — server replies `{"code":0,"message":"auth err"}` for every payload shape tried (see below) |
| End-to-end automated fetch | 🚧 blocked on the line above |

### What works today

- **Full login flow**, including the `securityStatus: 16` identity-verification
  wall (Xiaomi requires email/SMS confirmation for new devices). Implemented in
  [`fetcher/band10/xiaomi_2fa.py`](fetcher/band10/xiaomi_2fa.py): detects the
  wall, sends a verification email, accepts your code, marks the device trusted
  (`trust=true`), and extracts `ssecurity` from the `extension-pragma` header.
- **Session caching**: once you complete the email-code step *once*,
  `ssecurity` / `serviceToken` / cookies are cached to `fetcher/.mi_session.json`
  (mode 600, gitignored) and reused — no more verification prompts on
  subsequent runs.
- **Endpoint + auth_key discovery**: a live mitmproxy capture of Mi Fitness
  3.49.0 (iOS) confirmed the sleep data lives on the *regional* host
  (`{region}.hlth.io.mi.com`, e.g. `de.hlth.io.mi.com`), comes from
  `POST /app/v1/data/get_fitness_data_by_watermark`, and that the request
  additionally needs an `auth_key` cookie (your Band's pairing key — settable
  via `MI_AUTH_KEY` env var, see Quick start).

### What's blocking full automation

Even with a valid `serviceToken`, correct RC4 signing/encryption (vendored from
[huami-token](https://codeberg.org/argrento/huami-token/)), the right
`auth_key` cookie, and an iOS-style User-Agent, the data endpoints uniformly
reply **HTTP 401 `{"code":0,"message":"auth err"}`** — for every JSON shape we
tried in the `data` field (`data_type`, `watermark`, `start_time`/`end_time`,
`source`, `category`, …). This response is identical regardless of payload
content, which suggests the rejection happens *before* the payload is parsed —
likely some additional per-install/device fingerprint the official app sends
that we haven't identified.

We could not find this schema documented anywhere publicly (checked
Gadgetbridge, huami-token, AstroBox, hacking-mifit-api, zepp_to_influxdb — none
cover these specific `hlth.io.mi.com` watermark/statistics endpoints). The only
way to learn it would be decrypting the *phone app's own* traffic, which
requires *its* `ssecurity` — a value that's per-login-session and never appears
on the wire (each login, including the phone's, derives its own).

**If you can get further** (e.g. you find the right payload shape, or capture
your phone's `ssecurity` at the moment Mi Fitness logs in), `fetch_sleep()` in
[`fetcher/band10/health_client.py`](fetcher/band10/health_client.py) is ready
to be completed — pin your finding into `WORKING_ENDPOINTS["sleep"]`.

## Quick start (iOS, with sample data — no Xiaomi cloud needed)

This part works fully today.

```bash
open ios/Band10Health/Band10Health.xcodeproj
```

1. Select your iPhone as the run target, set your signing Team, run (⌘R).
2. In the app: **Richiedi accesso ad Apple Health** → enable the toggles.
3. AirDrop / put `sample_sleep.json` in Files, then **Scegli file JSON…**.
4. **Importa in Salute** → open Apple Health → Sleep to see the staged night.

## Quick start (fetcher — login works, data fetch is blocked)

```bash
cd fetcher
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
export MI_USER="you@example.com" MI_REGION="de"   # de = Europe
read -s MI_PASS && export MI_PASS

# First run: you'll get an email with a verification code (securityStatus 16).
# After that, the session is cached — no more codes needed.
.venv/bin/python -m band10.cli login

# Optional: skip auth_key auto-discovery (currently broken — get_source_list
# returns an empty device list for unknown reasons) by setting it directly.
# Find yours by capturing Mi Fitness traffic (see scripts/capture_help.md) and
# looking at the `cookie:` header of any /app/v1/ request — `auth_key=...`.
export MI_AUTH_KEY="your16charkey"

.venv/bin/python -m band10.cli probe   # currently returns "auth err" — see Status
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
