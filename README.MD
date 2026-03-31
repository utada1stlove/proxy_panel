# proxy_panel

A Bash management panel for [shoes](https://github.com/cfal/shoes) — a high-performance multi-protocol proxy written in Rust. Designed for one-click deployment on Debian/Ubuntu VPS.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/old/panel.sh | bash
```

> Requires root. Run inside `sudo -i` or `su -`.

## Features

- Auto-downloads and installs the shoes binary (detects x86_64 / aarch64)
- Writes a systemd service with auto-start on boot
- Interactive menu to add / remove / list proxy listeners
- Displays share URL immediately after adding a protocol
- Shows share URLs in the listener list
- One-click uninstall (removes binary, service, and config)
- Supported protocols:
  - HTTP
  - SOCKS5
  - Shadowsocks (aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305)
  - Shadowsocks 2022 (blake3-aes-128-gcm / blake3-aes-256-gcm / blake3-chacha20-ietf-poly1305)
  - Trojan (TLS)
  - VMess
  - VLESS (TLS)
  - VLESS-Reality (auto-generates X25519 keypair, shows public key + short ID for clients)
  - Hysteria2 (QUIC)
  - TUIC v5 (QUIC)

## Files

| File | Description |
|------|-------------|
| `panel.sh` | Main script — all functionality in a single file |

## Requirements

`curl`, `tar`, `systemctl` — all present by default on Debian/Ubuntu.

---

[中文说明](READMECN.md)
