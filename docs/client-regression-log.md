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
| HTTP | pending | pending | n/a | dae target focuses on proxy URIs it explicitly documents. |
| SOCKS5 | pending | pending | n/a | dae target matrix currently excludes raw SOCKS import checks here. |
| Shadowsocks | pending | pending | pending | Use SIP002 Base64URL userinfo export. |
| Shadowsocks 2022 | pending | pending | pending | Use plain AEAD-2022 `method:password@host:port`. |
| Trojan (TLS) | pending | pending | pending | Self-signed mode should preserve `allowInsecure=1&insecure=1`. |
| VMess | pending | pending | pending | Verify Base64 JSON import stays intact after QR scan. |
| VLESS (TLS) | pending | pending | pending | Confirm `sni` survives import. |
| VLESS-Reality | pending | pending | pending | Check `pbk`, `sid`, `fp`, `flow`, `sni`. |
| ShadowTLS native | pending | pending | n/a | Not part of dae target matrix. |
| ShadowTLS standalone | pending | pending | n/a | Check Shadowrocket combined `shadow-tls=` URI first. |
| Hysteria2 / HY2 | pending | pending | pending | Verify both `hysteria2://` and `hy2://` behavior where relevant. |
| TUIC v5 | pending | pending | pending | Check `alpn=h3`, `udp_relay_mode=native`, `congestion_control=cubic`. |

## Per-Run Notes

| Date | Client | Protocol | Result | Notes |
|---|---|---|---|---|
| _pending_ |  |  |  |  |
