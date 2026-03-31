# Client Regression Matrix

This file records the current export targets for `proxy_panel` before full live-client regression.

## Target Clients

| Client | Current Focus | Notes |
|---|---|---|
| Shadowrocket | Direct URI import | `ShadowTLS` stays client-specific and is not part of the `dae` target matrix. |
| v2rayN | Direct URI import and subscription text | v2rayN accepts subscription text that returns one URI per line. |
| dae | Direct URI import where dae documents the scheme | Follow dae-documented schemes first; avoid client-only extras unless necessary. |

## Export Rules

| Protocol | Current Export Rule |
|---|---|
| Shadowsocks | Use SIP002 style `ss://<Base64URL(method:password)>@host:port#tag` |
| Shadowsocks 2022 | Use plain SIP002 AEAD-2022 userinfo: `ss://method:password@host:port#tag` |
| ShadowTLS-SS | Follow the inner Shadowsocks cipher rule above, then append `/?plugin=shadow-tls...` |
| Trojan / VLESS over TLS | Self-signed mode uses `allowInsecure=1&insecure=1` |
| Hysteria2 / HY2 | Use `hysteria2://` and `hy2://`, include `/?` before query, self-signed mode uses `insecure=1` |
| TUIC | Keep `alpn=h3`, `udp_relay_mode=native`, `congestion_control=cubic`; self-signed mode uses `allow_insecure=1&insecure=1` |

## Manual Regression Checklist

1. Import the generated link into `Shadowrocket`.
2. Import the same link into `v2rayN`.
3. Import only dae-supported schemes into `dae`.
4. Confirm handshake, website access, and no missing parameters after import.
5. Record which client needs a protocol-specific fallback alias.
