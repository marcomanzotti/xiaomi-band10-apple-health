# Supported devices

| Device | Status |
|---|---|
| Xiaomi Smart Band 10 | **Verified**: key, authentication, steps, heart rate, SpO₂, daily summary, sleep (with or without stages), background sync |
| Xiaomi Smart Band 10 Pro, Smart Band 9 / 9 Pro / 9 Active, Smart Band 8 Pro, Redmi / Xiaomi watches on Mi Fitness | Untested. Same protocol family ("Xiaomi protobuf" in Gadgetbridge); likely to need small changes |
| Older Mi Band models (Zepp Life / Mi Fit) | Not supported: different protocol and app |

The key tool works for any device paired in Mi Fitness that has a key in the
account, so it is useful for Gadgetbridge users of other models too.

## Trying another model

1. Get the key and install Band Sync as described in the README.
2. Open Band Sync and look at the **Diary** at the bottom of the screen. It
   says whether the band authenticated, how many files were received, and
   which ones could not be read (and are therefore left on the band).
3. [Open an issue](../../../issues/new?template=device-report.md) with your
   model, firmware version and the diary lines. Do not paste your key.
