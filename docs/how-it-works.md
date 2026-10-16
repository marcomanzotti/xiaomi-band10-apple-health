# How it works

Everything below was established on a Xiaomi Smart Band 10 (firmware of
October 2026), starting from Gadgetbridge's implementation and the Mi Fitness
Android app, and checked against real traffic and real files. Where the band
differs from Gadgetbridge's layouts, it is said. The code is in
[`ios/Band10Kit/Sources/Band10Kit`](../ios/Band10Kit/Sources/Band10Kit).

## 1. The key

The band and its phone share a 16-byte **auth key**. A Band 10 only accepts
*server-assisted* pairing (`PSKWearBinderV2` in Mi Fitness): the band and
Xiaomi's server run an ECDH exchange through the app, and the server hands the
key to the app. Asked for local pairing, the band reports `verifyMode 1` and
drops the connection when forced. So the key always comes from Xiaomi once;
it is stored in the account and readable with the account's own session:

- log in to `account.xiaomi.com` with service id `miothealth`; the login
  yields `ssecurity` and, after the redirects, a `serviceToken` cookie;
- `POST https://{region}.hlth.io.mi.com/app/v1/source/get_source_list` with
  `data={"page_size":50,"status":1,"page_start":""}`; only the `serviceToken`
  cookie is required;
- parameters and reply are RC4-encrypted: key = SHA-256(ssecurity ‖ nonce),
  first 1024 keystream bytes dropped, nonce = 8 random bytes ‖ current minute
  (big endian), signed with SHA-1 over `METHOD&path&k=v…&key`;
- each wearable in `result.list[]` carries `detail.encrypt_key`: the key, as
  32 hex digits.

## 2. Bluetooth transport

GATT service `FE95`; the phone writes without response to `005F` and
subscribes to notifications on `005E` ("SPP V2 over BLE"). Every frame:

```
a5 a5 | type (low nibble) | sequence | length (2, LE) | CRC-16/ARC of payload (2, LE) | payload
```

Types: 0 NACK, 1 ACK, 2 session configuration, 3 data. Data frames are acked
by sequence number; sequence numbers are 8-bit and shared by both directions'
counters starting at 0 after each session start.

**Session.** The phone sends opcode 1 with TLVs (version 1.0.0, max packet
0xFC00, transmit window 32, timeout 10 000 ms); the Band 10 answers opcode 2
(max packet 0x8000, window 3, timeout 16 000 ms). Opcode 3 closes a session,
answered by 4. A session left open by a previous run of the app must be closed
first or the band ignores the new request.

**Data payload:** `channel | opcode | body`. Channel 1 carries protobuf
commands, 2 bulk uploads to the band, 5 activity files. Opcode 1 is plain,
2 encrypted.

## 3. Authentication

Commands are protobuf `Command {1 type, 2 subtype, 3 account, 4 system, 10 health, …}`.

1. Phone → band, type 1 subtype 26: a 16-byte random `phoneNonce`.
2. Band → phone: its `watchNonce` and a proof.
3. Both derive 64 bytes with HKDF-SHA256 (salt = phoneNonce ‖ watchNonce,
   input = auth key, info = `miwear-auth`): decryption key [0,16), encryption
   key [16,32), decryption nonce [32,36), encryption nonce [36,40).
   The band's proof must equal HMAC-SHA256(decryption key, watchNonce ‖ phoneNonce).
4. Phone → band, subtype 27: HMAC-SHA256(encryption key, phoneNonce ‖ watchNonce)
   and a `CompanionDevice` message sealed with AES-CCM (encryption key, nonce =
   encryption nonce ‖ 8 zero bytes, 4-byte tag).
5. Band → phone: subtype 27 = accepted. From now on command bodies are
   AES-CTR encrypted, each message from the start of the stream, with the key
   itself as initial counter (one key per direction).

**The phone must introduce itself as iOS over Bluetooth LE.** `CompanionDevice`
has a device type (0 Android, 1 iOS). Declaring Android from an iPhone made a
Band 10 stop listening on LE and become unreachable until a factory reset:
Android phones talk to it over Bluetooth Classic. AstroBox follows the same
rule (iOS over LE, Android over Classic). The app capability field is sent as
224, the value Gadgetbridge uses.

Practical findings:

- a bound band silently drops every unauthenticated request;
- after the app is relaunched, the band may resend the handshake reply of the
  previous session, whose proof does not match the new nonce: open a new
  session and retry once before concluding the key is wrong;
- if another app (Mi Fitness) authenticates on the same link, the band
  switches to that app's session keys and everything you decrypt becomes
  garbage: re-authenticate. In practice, remove the vendor app.

## 4. Commands used

| Type / subtype | Meaning |
|---|---|
| 2 / 1 | battery level |
| 2 / 3 | set clock: date, time, zone offset and DST offset in quarter hours (sint32), zone name, 12/24 h |
| 8 / 1 | list today's activity files (`health {5: {1: 0}}`) |
| 8 / 2 | list unacknowledged files of earlier days |
| 8 / 3 | request a file (`health {2: <7-byte id>}`) |
| 8 / 5 | acknowledge a file (`health {3: <7-byte id>}`): the band may delete it |

The band also sends requests of its own (weather, alarms…), which are not
needed for the sync.

## 5. Activity files

**File id**, 7 bytes: `timestamp (4, LE) | timezone (quarter hours) | version |
flags`, flags = `category << 7 | subtype << 2 | detail`. Category 0 is daily
activity (subtypes 0 daily, 3 sleep stages, 6 spot measurements, 8 sleep),
1 is workouts. Detail 0 details, 1 summary, 2 GPS.

**Transfer.** A requested file arrives on channel 5, encrypted, in pieces:
`piece count (2, LE) | piece number from 1 (2, LE) | bytes`. Joined, the file
is `id (7) | padding (1) | content | CRC-32 (4, LE)`.

Acknowledge a file only after it is saved and could be read: the band deletes
acknowledged files.

**Daily details** (per minute). The header has one nibble per value group:
top bit = group present, lower bits = which of its values are valid. Groups,
in order: 16-bit (bit 14: one extra byte follows the record; low 14 bits:
steps), 8-bit (low 6 bits: active kcal), 8-bit, 16-bit (distance, metres),
8-bit (heart rate), 8-bit (body energy), 16-bit, then from version 3 SpO₂ and
stress (8-bit each), from version 4 two more 16-bit groups. Header length:
4 bytes (v1-2), 5 (v3), 6 (v4). The Band 10 sends version 4.

**Daily summary** (version 5 on the Band 10). A 4-byte validity bitmap, then
fixed-width fields: steps (4), active kcal (2), reserved (1), resting HR (1),
max HR (1) and time (4), min HR (1) and time (4), average HR (1), stress
average/max/min, standing hours (3), total kcal (2), … **The Band 10's file
stops before the last two reserved 2-byte fields** of Gadgetbridge's layout,
which reads them from the CRC.

**Sleep** (subtype 8, version 5 on the Band 10). Preamble: header (2 bytes),
a flag that is **1 once the band has closed the sleep** (Gadgetbridge calls it
`isAwake`), bed time, wake time, then optional fields and sample series. Then
packets, each opened by `fb fa fc ff`:
`marker | header length (1) | timestamp (8, LE) | parity | type | data length (2, BE) | data`.

- Type 17: stages, big-endian pairs `stage (4 bits) | minutes (12 bits)`
  (0 awake, 1 light, 2 deep, 3 REM).
- Types 2 and 3: fell asleep / woke up, timestamps in **milliseconds**.
- Type 16: totals. Others (0, 1, 9-15, 18, 101) hold sensor data or flags;
  several use the length field for flags and carry no data, so a marker right
  after the header means "no data".

On the Band 10 the stage packets can be **empty** (the band did not stage that
sleep): the asleep periods then come from the type 2/3 events, and the gaps
between them count as awake.

**Spot measurements** (subtype 6, version 2): a run of
`time (4) | type (1) | value`; 0x11 heart rate, 0x12 SpO₂, 0x13 stress (1 byte
each), 0x44 skin temperature (4 bytes).

## 6. Writing to Apple Health

Every sample carries `HKMetadataKeySyncIdentifier` (kind + start time) and
`HKMetadataKeySyncVersion`, so receiving a file twice never duplicates data,
and a value that grows (the steps of the current minute, a night that gets
longer) replaces the older one. Steps, energy and distance are written per
minute; heart rate and SpO₂ as instant values; sleep as one category sample
per stage (`asleepCore` for light, `asleepUnspecified` when the band gave no
stage).

## 7. Background on iOS

`bluetooth-central` background mode with state restoration: after every
disconnection the app asks iOS to connect again, which completes whenever the
band is back in range and relaunches the app if it was terminated. The band's
own traffic wakes the app regularly; each wake starts a sync if the last one
is more than 15 minutes old. Files are written to disk with
`completeUntilFirstUserAuthentication` protection and moved to Health when the
phone is unlocked.
