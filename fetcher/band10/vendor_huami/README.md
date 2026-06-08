# Vendored from huami-token

These modules (`mi_crypto.py`, `xiaomi.py`, `constants.py`, `errors.py`) are
vendored, unmodified, from **huami-token** by Kirill Snezhko (argrento):

- Source: https://codeberg.org/argrento/huami-token/
- Mirror: https://github.com/argrento/huami-token
- License: MIT (see `LICENSE.huami-token.md`)

They implement the modern (2025) Xiaomi Mi Account login flow for the
`miothealth` service and the RC4/SHA1 request encryption used by the
`*.hlth.io.mi.com` health cloud — the backend that the Mi Fitness app and the
Xiaomi Smart Band 10 sync to.

We reuse them as our authentication + crypto foundation and build the
sleep-data endpoint on top (see `../health_client.py`).

No changes were made to these files. All credit to the original author.
