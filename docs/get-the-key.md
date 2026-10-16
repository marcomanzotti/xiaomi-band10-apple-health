# Getting the band key

Every Bluetooth session with the band starts with an authentication based on a
16-byte **auth key** shared by the band and its phone. It is created when the
band is paired. Recent Xiaomi bands (the Smart Band 10 included) refuse to
pair without Xiaomi's servers, so the key is generated there and stored in
your Xiaomi account. You need it once per pairing.

Pair the band with **Mi Fitness** first (iPhone or Android), then use one of
the methods below.

## Method 1 — log in from the terminal (recommended)

Needs Python 3 (preinstalled on macOS; on Windows/Linux install it from
python.org). Nothing else to install.

```sh
python3 tools/band-key/get_band_key.py --save band.key
```

1. Type the email, phone number or Xiaomi ID of the account the band is
   paired to, then the password (not shown while typing).
2. If Xiaomi does not know this computer, it sends a code by email or SMS:
   type it when asked. Sometimes it also asks for a captcha: the tool saves the
   image and tells you where to open it.
3. The tool finds your account's region by itself and prints each band:

   ```
     Xiaomi Smart Band 10  (miwear.watch.o66gl, MAC AA:BB:CC:DD:EE:FF, region de)
     key: 0123456789abcdef0123456789abcdef
   ```

`--save band.key` also writes the key to `band.key` with permissions that only
you can read. `--region de` skips the region search (`de`, `sg`, `us`, `ru`,
`i2`, `cn`).

**It does not work if** your Xiaomi account has no password (you always sign
in with Google or Apple). Set a password in your Xiaomi account settings, or
use method 2.

## Method 2 — capture Mi Fitness logging in (fallback)

Uses [mitmproxy](https://mitmproxy.org) on a computer to watch the phone's
connection to Xiaomi while Mi Fitness logs in; an add-on in this repository
decrypts the device list and prints the key. Nothing is written to disk.

1. Install mitmproxy (`brew install mitmproxy` on macOS).
2. Start it from the repository folder:

   ```sh
   mitmdump -q --allow-hosts 'xiaomi\.com|mi\.com' -s tools/band-key/band_key/capture_addon.py
   ```

3. On the phone, set the Wi-Fi HTTP proxy to your computer's IP address, port
   8080. Turn off any VPN on the computer and the phone.
4. Install the mitmproxy certificate on the phone: open `http://mitm.it` in the
   phone's browser and follow the instructions. **On iPhone** also enable full
   trust: Settings → General → About → Certificate Trust Settings.
5. In Mi Fitness: log out, then log in again. The terminal prints the key.
6. Remove the proxy setting and the certificate from the phone afterwards.

## Method 3 — Android logs

On Android, some Mi Fitness versions write the key to their own log files.
The Gadgetbridge community documents this; see the
[Gadgetbridge Xiaomi page](https://gadgetbridge.org/basics/topics/xiaomi-protobuf/).

## After you have the key

- iPhone: `ios/install.sh --key band.key`, or paste it in Band Sync →
  *Band key* → *Paste* → *Save key*. See [iPhone guide](iphone.md).
- Android: enter it in Gadgetbridge when adding the band. See
  [Android guide](android.md).

Then **delete Mi Fitness** (do not "unpair" the band in it first: that
deletes the key). The band stays paired. If you ever pair it again, the key
changes and you run this again.
