# Troubleshooting

Band Sync keeps a short **diary** at the bottom of its screen. Start there.

## The key

| Symptom | Fix |
|---|---|
| `Login failed: wrong email/phone or password` | Use the account the band is paired to in Mi Fitness. If you always sign in with Google/Apple, set a password for the Xiaomi account or use the [capture method](get-the-key.md#method-2--capture-mi-fitness-logging-in-fallback). |
| `No band with a key was found` | The band is not paired in this account (or was unpaired). Pair it in Mi Fitness and run the tool again. |
| The diary says `authentication failed: keyMismatch` twice | The band was paired again and has a new key: run the key tool again and save the new key in the app. |

## Connection

| Symptom | Fix |
|---|---|
| Status stays at *waiting for the band to be near* | Mi Fitness or another app may be holding the band: force-quit or delete it. Toggle Bluetooth off and on. |
| `the band uses keys of another session (another app?)` | Another app authenticated with the band. Delete Mi Fitness. |
| No sync for hours | Do not swipe Band Sync away in the app switcher. After an iPhone restart, unlock it once. After 7 days with a free Apple ID, reinstall. |
| The band stopped connecting to any phone | Factory-reset the band, pair it with Mi Fitness, get the new key. (This happened when a phone introduced itself to the band as Android over Bluetooth LE; this app always says iOS.) |

## Health

| Symptom | Fix |
|---|---|
| *Health does not let this app write…* | Settings → Privacy & Security → Health → Band Sync → turn on everything under **Allow to write**. Files already downloaded are written automatically afterwards. |
| *Files waiting for Health* does not go down | Health cannot be written while the phone is locked: unlock it. |
| Steps look double | They are not counted twice: Health counts overlapping sources once. Check Health → Steps → Show All Data to see each source. |
| Sleep shows no stages | The band did not compute stages for that sleep (it often does not for short sleeps). The time asleep is still recorded. |

## Reinstall every 7 days

`ios/install.sh` again (the key and the data stay). If the app does not open
after a reinstall: Settings → General → VPN & Device Management → Trust.
