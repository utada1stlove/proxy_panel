#!/usr/bin/env bash
# panel.sh — shoes proxy management panel for Debian/Ubuntu VPS
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
SHOES_VERSION="v0.2.7"
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONFIG_DIR="/etc/shoes"
SHOES_CONFIG="$SHOES_CONFIG_DIR/config.yaml"
SHOES_SERVICE="/etc/systemd/system/shoes.service"
GITHUB_RELEASE_BASE="https://github.com/cfal/shoes/releases/download/${SHOES_VERSION}"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[x]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}$*${RESET}\n"; }

# ─── Root guard ───────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { error "This script must be run as root."; exit 1; }
}

# ─── Arch detection ───────────────────────────────────────────────────────────
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        *) error "Unsupported architecture: $machine"; exit 1 ;;
    esac
}

# ─── Install / upgrade shoes binary ───────────────────────────────────────────
install_shoes() {
    header "Install / Upgrade shoes ${SHOES_VERSION}"
    local arch tarball url tmpdir

    arch="$(detect_arch)"
    tarball="shoes-${arch}.tar.gz"
    url="${GITHUB_RELEASE_BASE}/${tarball}"
    tmpdir="$(mktemp -d)"

    info "Downloading $tarball ..."
    curl -fsSL "$url" -o "${tmpdir}/${tarball}"
    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"

    local binary
    binary="$(find "$tmpdir" -maxdepth 2 -type f -name shoes | head -1)"
    [[ -n "$binary" ]] || { error "Could not find shoes binary in archive."; rm -rf "$tmpdir"; exit 1; }

    install -m 755 "$binary" "$SHOES_BIN"
    rm -rf "$tmpdir"

    info "shoes installed to $SHOES_BIN"
    "$SHOES_BIN" --version 2>/dev/null || true
}

# ─── Systemd service ──────────────────────────────────────────────────────────
write_service() {
    cat > "$SHOES_SERVICE" <<EOF
[Unit]
Description=shoes proxy server
After=network.target

[Service]
Type=simple
ExecStart=$SHOES_BIN $SHOES_CONFIG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable shoes
    info "shoes.service written and enabled."
}

service_action() {
    local action="$1"
    systemctl "$action" shoes && info "shoes $action OK." || warn "systemctl $action shoes returned an error."
}

show_status() {
    systemctl status shoes --no-pager || true
}

# ─── Config helpers ───────────────────────────────────────────────────────────
init_config() {
    mkdir -p "$SHOES_CONFIG_DIR"
    [[ -f "$SHOES_CONFIG" ]] || { echo "# shoes config" > "$SHOES_CONFIG"; info "Created $SHOES_CONFIG"; }
}

# Append a raw YAML listener block (string) to the config
add_listener() {
    local block="$1"
    init_config
    echo "" >> "$SHOES_CONFIG"
    echo "$block" >> "$SHOES_CONFIG"
}

# List configured listener ports by scanning address: lines
list_listeners() {
    header "Configured listeners"
    init_config
    local found=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^-[[:space:]]*address:[[:space:]]*(.*) ]]; then
            echo "  ${BASH_REMATCH[1]}"
            found=1
        fi
    done < "$SHOES_CONFIG"
    [[ $found -eq 1 ]] || warn "No listeners found in $SHOES_CONFIG"
}

# Remove a listener by port number (deletes the block starting with "- address: 0.0.0.0:<port>")
remove_listener() {
    local port="$1"
    init_config
    local pattern="^- address: 0\\.0\\.0\\.0:${port}$"

    # Build a new config without the matching block
    # A block starts with "- address:" and ends before the next "- address:" or EOF
    local tmpfile
    tmpfile="$(mktemp)"
    awk -v pat="$pattern" '
        /^- address:/ {
            if (buffer != "" && !skip) printf "%s", buffer
            skip = ($0 ~ pat)
            buffer = $0 "\n"
            next
        }
        {
            if (!skip) buffer = buffer $0 "\n"
            else        buffer = buffer $0 "\n"   # still accumulate to drop on next header
        }
        END {
            if (!skip && buffer != "") printf "%s", buffer
        }
    ' "$SHOES_CONFIG" > "$tmpfile"

    mv "$tmpfile" "$SHOES_CONFIG"
    info "Removed listener on port $port (if it existed)."
}

# ─── Protocol wizards ─────────────────────────────────────────────────────────
prompt_port() {
    local port
    while true; do
        read -rp "  Port [1-65535]: " port
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && break
        warn "Invalid port number."
    done
    echo "$port"
}

prompt_password() {
    local pass
    read -rp "  Password: " pass
    echo "$pass"
}

prompt_uuid() {
    local uuid
    while true; do
        read -rp "  UUID (e.g. from uuidgen): " uuid
        [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] && break
        warn "Doesn't look like a valid UUID."
    done
    echo "$uuid"
}

add_http() {
    header "Add HTTP proxy"
    local port; port="$(prompt_port)"
    local user pass
    read -rp "  Username (leave blank for no auth): " user
    local block
    if [[ -z "$user" ]]; then
        block="- address: 0.0.0.0:${port}
  protocol:
    type: http"
    else
        pass="$(prompt_password)"
        block="- address: 0.0.0.0:${port}
  protocol:
    type: http
    users:
      - username: ${user}
        password: ${pass}"
    fi
    add_listener "$block"
    info "HTTP proxy added on port $port."
}

add_socks5() {
    header "Add SOCKS5 proxy"
    local port; port="$(prompt_port)"
    local user pass
    read -rp "  Username (leave blank for no auth): " user
    local block
    if [[ -z "$user" ]]; then
        block="- address: 0.0.0.0:${port}
  protocol:
    type: socks5"
    else
        pass="$(prompt_password)"
        block="- address: 0.0.0.0:${port}
  protocol:
    type: socks5
    users:
      - username: ${user}
        password: ${pass}"
    fi
    add_listener "$block"
    info "SOCKS5 proxy added on port $port."
}

add_shadowsocks() {
    header "Add Shadowsocks proxy"
    local port; port="$(prompt_port)"
    local cipher pass
    echo "  Cipher options: aes-128-gcm, aes-256-gcm, chacha20-ietf-poly1305"
    read -rp "  Cipher [chacha20-ietf-poly1305]: " cipher
    cipher="${cipher:-chacha20-ietf-poly1305}"
    pass="$(prompt_password)"
    local block="- address: 0.0.0.0:${port}
  protocol:
    type: shadowsocks
    cipher: ${cipher}
    password: ${pass}"
    add_listener "$block"
    info "Shadowsocks added on port $port."
}

add_trojan() {
    header "Add Trojan proxy"
    local port; port="$(prompt_port)"
    local pass; pass="$(prompt_password)"
    local cert key
    read -rp "  TLS cert path: " cert
    read -rp "  TLS key path:  " key
    local block="- address: 0.0.0.0:${port}
  protocol:
    type: tls
    cert: ${cert}
    key: ${key}
    protocol:
      type: trojan
      password: ${pass}"
    add_listener "$block"
    info "Trojan added on port $port."
}

add_vmess() {
    header "Add VMess proxy"
    local port; port="$(prompt_port)"
    local uuid; uuid="$(prompt_uuid)"
    local block="- address: 0.0.0.0:${port}
  protocol:
    type: vmess
    user_id: ${uuid}"
    add_listener "$block"
    info "VMess added on port $port."
}

add_vless() {
    header "Add VLESS proxy"
    local port; port="$(prompt_port)"
    local uuid; uuid="$(prompt_uuid)"
    local cert key
    read -rp "  TLS cert path: " cert
    read -rp "  TLS key path:  " key
    local block="- address: 0.0.0.0:${port}
  protocol:
    type: tls
    cert: ${cert}
    key: ${key}
    protocol:
      type: vless
      user_id: ${uuid}"
    add_listener "$block"
    info "VLESS added on port $port."
}

add_hysteria2() {
    header "Add Hysteria2 proxy"
    local port; port="$(prompt_port)"
    local pass; pass="$(prompt_password)"
    local cert key
    read -rp "  TLS cert path: " cert
    read -rp "  TLS key path:  " key
    local block="- address: 0.0.0.0:${port}
  transport: quic
  quic_settings:
    cert: ${cert}
    key: ${key}
  protocol:
    type: hysteria2
    password: ${pass}"
    add_listener "$block"
    info "Hysteria2 added on port $port."
}

add_tuic() {
    header "Add TUIC v5 proxy"
    local port; port="$(prompt_port)"
    local uuid; uuid="$(prompt_uuid)"
    local pass; pass="$(prompt_password)"
    local cert key
    read -rp "  TLS cert path: " cert
    read -rp "  TLS key path:  " key
    local block="- address: 0.0.0.0:${port}
  transport: quic
  quic_settings:
    cert: ${cert}
    key: ${key}
  protocol:
    type: tuic
    user_id: ${uuid}
    password: ${pass}"
    add_listener "$block"
    info "TUIC v5 added on port $port."
}

# ─── Add protocol sub-menu ────────────────────────────────────────────────────
menu_add_protocol() {
    header "Add Protocol"
    local options=(
        "HTTP"
        "SOCKS5"
        "Shadowsocks"
        "Trojan (TLS)"
        "VMess"
        "VLESS (TLS)"
        "Hysteria2 (QUIC)"
        "TUIC v5 (QUIC)"
        "Back"
    )
    select choice in "${options[@]}"; do
        case "$choice" in
            "HTTP")              add_http;       break ;;
            "SOCKS5")           add_socks5;     break ;;
            "Shadowsocks")      add_shadowsocks; break ;;
            "Trojan (TLS)")     add_trojan;     break ;;
            "VMess")            add_vmess;      break ;;
            "VLESS (TLS)")      add_vless;      break ;;
            "Hysteria2 (QUIC)") add_hysteria2;  break ;;
            "TUIC v5 (QUIC)")   add_tuic;       break ;;
            "Back")             break ;;
            *) warn "Invalid selection." ;;
        esac
    done
    # Reload if service is running
    if systemctl is-active --quiet shoes 2>/dev/null; then
        service_action restart
    fi
}

# ─── Remove listener sub-menu ─────────────────────────────────────────────────
menu_remove_listener() {
    list_listeners
    local port
    read -rp "  Enter port to remove: " port
    [[ "$port" =~ ^[0-9]+$ ]] || { warn "Not a valid port."; return; }
    remove_listener "$port"
    if systemctl is-active --quiet shoes 2>/dev/null; then
        service_action restart
    fi
}

# ─── Service sub-menu ─────────────────────────────────────────────────────────
menu_service() {
    header "Service Management"
    local options=("Start" "Stop" "Restart" "Status" "Back")
    select choice in "${options[@]}"; do
        case "$choice" in
            "Start")   service_action start;   break ;;
            "Stop")    service_action stop;    break ;;
            "Restart") service_action restart; break ;;
            "Status")  show_status;            break ;;
            "Back")    break ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

# ─── Main menu ────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        header "shoes Proxy Panel  [${SHOES_VERSION}]"
        local options=(
            "Install / Upgrade shoes"
            "Add protocol"
            "List protocols"
            "Remove protocol"
            "Service management"
            "Exit"
        )
        select choice in "${options[@]}"; do
            case "$choice" in
                "Install / Upgrade shoes")
                    install_shoes
                    write_service
                    break ;;
                "Add protocol")
                    menu_add_protocol
                    break ;;
                "List protocols")
                    list_listeners
                    break ;;
                "Remove protocol")
                    menu_remove_listener
                    break ;;
                "Service management")
                    menu_service
                    break ;;
                "Exit")
                    echo "Bye."; exit 0 ;;
                *) warn "Invalid selection." ;;
            esac
        done
    done
}

# ─── Entry point ──────────────────────────────────────────────────────────────
require_root
main_menu
