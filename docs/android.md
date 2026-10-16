# Android: Gadgetbridge + Health Connect

On Android there is no need for a new app: [Gadgetbridge](https://gadgetbridge.org)
is a mature, open-source companion that talks to Xiaomi bands directly, keeps
the data on the phone, and can write it to **Health Connect**. What it needs
for the Band 10 is the auth key, which [the key tool](get-the-key.md) gives you
even if you never had root or Android logs.

1. Pair the band with Mi Fitness once and [get the key](get-the-key.md).
2. Install Gadgetbridge from [F-Droid](https://f-droid.org/packages/nodomain.freeyourgadget.gadgetbridge/).
3. Close Mi Fitness completely (force stop it, or uninstall it).
4. In Gadgetbridge add the band and enter the key when asked. Gadgetbridge's
   own instructions for Xiaomi bands, including how to put the band in pairing
   mode, are on its [Xiaomi page](https://gadgetbridge.org/basics/topics/xiaomi-protobuf/).
5. Turn on the **Health Connect** integration in Gadgetbridge's settings:
   see [Health Connect in Gadgetbridge](https://gadgetbridge.org/basics/integrations/health-connect/).

Support for the Band 10 in Gadgetbridge is marked experimental there; check
its issue tracker for the current state of your model and firmware.
