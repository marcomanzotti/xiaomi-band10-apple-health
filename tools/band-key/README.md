# band-key

Gets the Bluetooth auth key of your Xiaomi band from your own Xiaomi account.
Standard-library Python 3.9+, nothing to install.

```sh
python3 get_band_key.py --save band.key
```

Full guide, including the mitmproxy fallback (`band_key/capture_addon.py`):
[docs/get-the-key.md](../../docs/get-the-key.md).

Tests: `python3 -m unittest discover -s tests -t .`
