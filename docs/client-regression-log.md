# Client Regression Log

This file is the live tracking sheet for manual client checks against `proxy_panel` exports.

Use the panel's `Share links / QR` menu to reopen the exact URI and QR for the listener under test.

## Status Legend

- `pending`: not tested yet
- `pass`: imported and connected successfully
- `partial`: imported, but needed manual edits or had limited connectivity
- `fail`: import failed or traffic could not be established
- `n/a`: intentionally not in that client's support target

## Current Matrix

| Protocol | Shadowrocket | v2rayN | dae | Notes |
|---|---|---|---|---|
| HTTP | pending | pending | n/a | dae target focuses on live-verified URI exports only. |
| SOCKS5 | pending | pending | n/a | dae target matrix currently excludes raw SOCKS import checks here. |
| Shadowsocks | pending | pending | pass | Live dae check passed with SIP002 Base64URL userinfo export. |
| Shadowsocks 2022 | pending | pending | pending | Exported as the normal AEAD-2022 `ss://method:password@host:port` URL again; re-check on a post-PR936 dae build when convenient. |
| Trojan (TLS) | pending | pending | pass | Self-signed mode preserved `allowInsecure=1&insecure=1` and connected. |
| VMess | pending | pending | pass | dae imported the Base64 JSON URI and established live traffic. |
| VLESS (TLS) | pending | pending | pass | dae preserved `sni` and established live traffic. |
| VLESS-Reality | pending | pending | pass | Live dae check passed with `pbk`, `sid`, `fp`, `flow`, `sni`. |
| ShadowTLS native | pending | pending | n/a | Not part of dae target matrix. |
| ShadowTLS standalone | pending | pending | n/a | Check Shadowrocket combined `shadow-tls=` URI first. |
| Hysteria2 / HY2 | pending | pending | pass | dae accepted the exported `hy2://` URI after the panel converted it to `hysteria2://`. |
| TUIC v5 | pending | pending | pass | Live dae check passed with `alpn=h3`, `udp_relay_mode=native`, `congestion_control=cubic`. |

## Per-Run Notes

| Date | Client | Protocol | Result | Notes |
|---|---|---|---|---|
| 2026-04-01 | dae | Shadowsocks | pass | Live traffic on `hk` VPS via temp `dae v1.0.0` and temp `shoes v0.2.7`; same-host harness added `pname(shoes) -> direct`. |
| 2026-04-01 | dae | Shadowsocks 2022 | fail | Temporary `dae v1.0.0` harness logged `unsupported shadowsocks encryption method: 2022-blake3-aes-256-gcm`; panel no longer treats that as a permanent export restriction. |
| 2026-04-01 | dae | VMess | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=VMess-32004`. |
| 2026-04-01 | dae | Trojan (TLS) | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=Trojan-32005`. |
| 2026-04-01 | dae | VLESS (TLS) | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=VLESS-32006`. |
| 2026-04-01 | dae | VLESS-Reality | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=VLESS-Reality-32007`. |
| 2026-04-01 | dae | Hysteria2 / HY2 | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=HY2-32008`. |
| 2026-04-01 | dae | TUIC v5 | pass | `curl https://ifconfig.me/ip` returned `43.99.71.31`; log showed `dialer=TUIC-32009`. |
