# Contributing

Reports from other models are the most useful contribution: see
[supported devices](docs/supported-devices.md#trying-another-model).

## Never share

- your band key or `band.key`;
- traffic captures (`.mitm` files): they contain your account tokens;
- raw activity files, unless you have looked at them: they are your health data.

## Running the tests

```sh
# Band protocol, file formats, sync engine (macOS, Xcode installed)
cd ios/Band10Kit
swift test --scratch-path ~/.cache/band10kit-build   # keep build products out of iCloud folders

# Key tool (any Python 3.9+)
cd tools/band-key
python3 -m unittest discover -s tests -t .
```

## Adding support for a file layout

1. Write a test with a fixture built by hand from the layout (see
   `ios/Band10Kit/Tests/Band10KitTests/ActivityFileTests.swift`); never commit
   a real file.
2. Change the parser in `ios/Band10Kit/Sources/Band10Kit/Activity/`.
3. A file the parser cannot read is kept on the band and on the phone, so a
   parser fix can process it later: keep it that way.

Code is AGPL-3.0-or-later; by contributing you agree to license your changes
under it.
