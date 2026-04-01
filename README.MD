# proxy_panel

A Bash management panel for [shoes](https://github.com/cfal/shoes) — a high-performance multi-protocol proxy written in Rust. Designed for one-click deployment on Debian/Ubuntu VPS.

## Quick Start

```bash
wget -c https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh && chmod +x panel.sh && ./panel
```

> Requires root. Run inside `sudo -i` or `su -`.

## Features

- Auto-downloads and installs the shoes binary (detects x86_64 / aarch64)
- Prompts to install shoes before protocol/service actions if the binary is missing
- Writes a systemd service with auto-start on boot
- Interactive menu to add / remove / list proxy listeners
- Listener list is rendered as a bordered table instead of loose line output
- The table is now only the overview; full import links are rendered again below as separate "Share Details" blocks
- Validates generated `shoes` config with `--dry-run` before keeping changes
- Displays generated share links immediately after adding a protocol in a dedicated share card layout
- Adds a dedicated `Share links / QR` menu so you can choose specific share URLs, print only their QR codes, or export client-oriented snippets
- Long share URLs are split at `@`, `?`, `&`, and `#` boundaries instead of being cut as a single raw line
- Stores multiple import URLs when a protocol benefits from compatibility aliases (for example `hysteria2://` + `hy2://`)
- Share blocks now print a single raw URL line for direct copy instead of inserting hard line breaks into the link itself
- Share URLs are now tuned primarily for Shadowrocket, v2rayN, and dae; self-signed TLS flows can include `allowInsecure` / `insecure` flags directly in the URL
- `ShadowTLS` now asks which mode you want: `shoes` native single-port mode, or Shadowrocket-style standalone mode with a separate SS2022 backend port
- Shadowsocks export now follows the panel's current compatibility format: classic Shadowsocks uses Base64URL userinfo, while `SS2022` exports `method:password` as a standard Base64 userinfo block
- `Remove protocol` uses `fzf` multi-select: press `Tab` to mark listeners, then `Enter` to delete them in batch
- `Share links / QR` also supports multi-select; with `fzf` installed you can pick one or more links and print just those share cards and QR codes
- The same menu can export selected links as plain subscription text for v2rayN, as a dae-friendly `node { ... }` snippet, or as a minimal runnable dae config that skips entries outside the current dae export target such as `ShadowTLS`
- Manages TLS certificates:
  - create self-signed certs under `/etc/shoes/certs/`
  - issue Let's Encrypt certs with `acme.sh` standalone mode
  - reuse managed certs when adding TLS / QUIC protocols
- Manages UDP firewall rules with nftables:
  - block arbitrary UDP ports or ranges
  - choose `input`, `output`, or `both`
  - persist managed rules in `/etc/shoes/proxy-panel-firewall.nft`
- Adds a `journalctl` log viewer for the `shoes` service
- One-click uninstall (removes binary, service, and config)
- Stores managed listeners as separate YAML fragments under `/etc/shoes/listeners.d/` and rebuilds `/etc/shoes/config.yaml`
- Supported protocols:
  - HTTP
  - SOCKS5
  - Shadowsocks (aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305)
  - Shadowsocks 2022 (blake3-aes-128-gcm / blake3-aes-256-gcm / blake3-chacha20-ietf-poly1305)
  - Trojan (TLS)
  - VMess
  - VLESS (TLS)
  - VLESS-Reality (auto-generates X25519 keypair, shows public key + short ID for clients)
  - ShadowTLS v3
  - Hysteria2 (QUIC)
  - TUIC v5 (QUIC)

## Files

| File | Description |
|------|-------------|
| `panel.sh` | Main script — installs `shoes`, manages listeners, certificates, UDP firewall rules, validates config, and shows logs |
| `docs/client-regression.md` | Current target matrix and manual regression checklist for Shadowrocket / v2rayN / dae |
| `docs/client-regression-log.md` | Live tracker for real client import / handshake / connectivity results |

## Requirements

`curl`, `tar`, `systemctl` — all present by default on Debian/Ubuntu. `fzf` is optional and is used for Tab multi-select in both listener deletion and `Share links / QR`; without it the panel falls back to numbered selection. `qrencode` is optional; when present, the panel prints QR codes for newly generated share links and for the dedicated QR view.

## Client Notes

- Share URL tuning currently targets `Shadowrocket`, `v2rayN`, and `dae`
- `dae` export currently targets classic `Shadowsocks`, `SS2022`, `VMess`, `Trojan`, `VLESS`, `VLESS-Reality`, `Hysteria2/HY2`, and `TUIC`
- `ShadowTLS` is intentionally excluded from the `dae` target matrix; `SS2022` is exported as `ss://BASE64(method:password)@host:port`
- `Share links / QR` can print selected URIs as one-link-per-line subscription text, generate a dae `node { ... }` snippet, or output a minimal dae config for the current selection
- For self-signed certificates, the panel can embed `allowInsecure` / `insecure` flags directly in generated URLs
- `Hysteria2` uses the official `/?query` URI form; `TUIC` keeps `allow_insecure` for dae-style import while also emitting `insecure`

---

[中文说明](READMECN.md)
