# proxy_panel

A Bash management panel for [shoes](https://github.com/cfal/shoes) — a high-performance multi-protocol proxy written in Rust. Designed for one-click deployment on Debian/Ubuntu VPS.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh | bash
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
- Long share URLs are split at `@`, `?`, `&`, and `#` boundaries instead of being cut as a single raw line
- Stores multiple import URLs when a protocol benefits from compatibility aliases (for example `hysteria2://` + `hy2://`, or ShadowTLS + `ss://...plugin=shadow-tls`)
- Share URLs are now tuned primarily for Shadowrocket, v2rayN, and dae; self-signed TLS flows can include `allowInsecure` / `insecure` flags directly in the URL
- `Remove protocol` uses `fzf` multi-select: press `Tab` to mark listeners, then `Enter` to delete them in batch
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

## Requirements

`curl`, `tar`, `systemctl` — all present by default on Debian/Ubuntu. `fzf` is optional and the panel can offer to install it when multi-select removal is used. `qrencode` is optional; when present, the panel prints QR codes for newly generated share links.

## Client Notes

- Share URL tuning currently targets `Shadowrocket`, `v2rayN`, and `dae`
- `dae` compatibility is considered only for protocols it documents; `ShadowTLS` is intentionally excluded from the `dae` target matrix
- For self-signed certificates, the panel can embed `allowInsecure` / `insecure` flags directly in generated URLs

---

[中文说明](READMECN.md)
