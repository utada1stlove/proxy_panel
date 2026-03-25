# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Bash shell panel script for managing a high-performance Rust proxy server on Debian VPS. It is derived from / adapts [shoes](https://github.com/cfal/shoes) — a Rust-based multi-protocol proxy.

**Key features planned:**
- Systemd service integration for persistent operation and auto-start on boot
- Menu-driven interface for adding/removing proxy protocols
- One-click deployment targeting Debian/Ubuntu VPS environments

## Architecture

- **Language:** Bash/Shell scripting
- **Target OS:** Debian/Ubuntu (systemd-based)
- **Underlying proxy binary:** `shoes` (Rust, downloaded/installed by the script)
- **Service management:** systemd unit files

The panel script is expected to:
1. Download and install the `shoes` binary
2. Generate systemd unit files for the proxy service
3. Provide an interactive menu for managing proxy protocols (add/remove/list)
4. Handle firewall rules if needed

## Development Notes

- Scripts should target POSIX-compatible shell where possible, using Bash only for features unavailable in POSIX sh
- Systemd unit files go under `/etc/systemd/system/`
- Configuration for `shoes` is typically a TOML file; consult the upstream [shoes](https://github.com/cfal/shoes) repo for schema details
