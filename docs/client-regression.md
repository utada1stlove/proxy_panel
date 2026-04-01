# Client Regression Matrix

This file records the current export targets for `proxy_panel` before full live-client regression.

Use the panel's `Share links / QR` menu when you need to re-open only a specific protocol URI during manual client checks. The same menu can also export:

- one URI per line for v2rayN-style subscription text
- a dae `node { ... }` snippet for the currently live-verified dae protocol set
- a minimal dae config for Linux-side verification of the selected nodes

Write actual test results into [client-regression-log.md](./client-regression-log.md).

## Target Clients

| Client | Current Focus | Notes |
|---|---|---|
| Shadowrocket | Direct URI import | `ShadowTLS` stays client-specific and is not part of the `dae` target matrix. |
| v2rayN | Direct URI import and subscription text | v2rayN accepts subscription text that returns one URI per line. |
| dae | Direct URI import where dae was live-verified on Linux | Current live-verified set: classic SS, VMess, Trojan TLS, VLESS TLS, VLESS-Reality, Hysteria2/HY2, TUIC. `SS2022` and `ShadowTLS` are skipped. |

## Export Rules

| Protocol | Current Export Rule |
|---|---|
| Shadowsocks | Use SIP002 style `ss://<Base64URL(method:password)>@host:port#tag` |
| Shadowsocks 2022 | Use plain SIP002 AEAD-2022 userinfo: `ss://method:password@host:port#tag` |
| ShadowTLS | Two modes now exist: `shoes` native single-port mode, or `Shadowrocket` standalone mode with a separate SS2022 backend port and a `shadow-tls=` combined link |
| Trojan / VLESS over TLS | Self-signed mode uses `allowInsecure=1&insecure=1` |
| Hysteria2 / HY2 | Use `hysteria2://` and `hy2://`, include `/?` before query, self-signed mode uses `insecure=1` |
| TUIC | Keep `alpn=h3`, `udp_relay_mode=native`, `congestion_control=cubic`; self-signed mode uses `allow_insecure=1&insecure=1` |

## Current dae Results

- Date: `2026-04-01`
- Host: `hk` VPS
- Harness: temporary `dae v1.0.0` plus temporary `shoes v0.2.7`
- Live-verified protocols: `Shadowsocks`, `VMess`, `Trojan (TLS)`, `VLESS (TLS)`, `VLESS-Reality`, `Hysteria2 / HY2`, `TUIC`
- Rejected by current dae build: `Shadowsocks 2022`
- Excluded from dae target matrix: `ShadowTLS`, `HTTP`, `SOCKS5`

Notes:

- Same-host dae checks needed `pname(shoes) -> direct` in the test harness so the local `shoes` server did not proxy its own outbound traffic back into dae.
- `SS2022` validation reached dae, but live run failed with `unsupported shadowsocks encryption method: 2022-blake3-aes-256-gcm`, so the panel now skips `SS2022` when exporting dae snippets or dae minimal configs.

## Manual Regression Checklist

1. Import the generated link into `Shadowrocket`.
2. Import the same link into `v2rayN`.
3. Import only dae-supported schemes into `dae`.
4. Use `Share links / QR` to re-open the exact URI and QR for the protocol under test, instead of copying from the full listener list.
5. Confirm handshake, website access, and no missing parameters after import.
6. Record which client needs a protocol-specific fallback alias.
