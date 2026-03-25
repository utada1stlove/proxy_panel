#!/usr/bin/env bash
# panel.sh — shoes proxy management panel for Debian/Ubuntu VPS
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
SHOES_VERSION="v0.2.7"
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONFIG_DIR="/etc/shoes"
SHOES_CONFIG="$SHOES_CONFIG_DIR/config.yaml"
SHOES_URLS="$SHOES_CONFIG_DIR/urls.conf"
SHOES_SERVICE="/etc/systemd/system/shoes.service"
GITHUB_RELEASE_BASE="https://github.com/cfal/shoes/releases/download/${SHOES_VERSION}"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[x]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}$*${RESET}\n"; }

# ─── TTY fix: when piped (curl | bash), stdin is the pipe not the terminal ────
if [[ ! -t 0 ]]; then
    exec < /dev/tty 2>/dev/null || {
        echo "No TTY available. Please run:"
        echo "  curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh -o /tmp/panel.sh && bash /tmp/panel.sh"
        exit 1
    }
fi

# ─── Root guard ───────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || { error "This script must be run as root."; exit 1; }
}

# ─── Arch detection ───────────────────────────────────────────────────────────
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)         echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64)  echo "aarch64-unknown-linux-musl" ;;
        *) error "Unsupported architecture: $machine"; exit 1 ;;
    esac
}

# ─── Get public IP ────────────────────────────────────────────────────────────
get_server_ip() {
    curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
        || hostname -I | awk '{print $1}'
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

# ─── Uninstall ────────────────────────────────────────────────────────────────
uninstall_shoes() {
    header "Uninstall shoes"
    warn "This will stop and remove shoes, its service, and all configuration."
    read -rp "  Are you sure? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; return; }

    if systemctl is-active --quiet shoes 2>/dev/null; then
        systemctl stop shoes
        info "Service stopped."
    fi
    if systemctl is-enabled --quiet shoes 2>/dev/null; then
        systemctl disable shoes
        info "Service disabled."
    fi
    [[ -f "$SHOES_SERVICE" ]] && { rm -f "$SHOES_SERVICE"; info "Removed $SHOES_SERVICE"; }
    systemctl daemon-reload

    [[ -f "$SHOES_BIN" ]] && { rm -f "$SHOES_BIN"; info "Removed $SHOES_BIN"; }
    [[ -d "$SHOES_CONFIG_DIR" ]] && { rm -rf "$SHOES_CONFIG_DIR"; info "Removed $SHOES_CONFIG_DIR"; }

    info "Uninstall complete."
    exit 0
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

# ─── URL store ────────────────────────────────────────────────────────────────
# Format: PORT|LABEL|URL  (one entry per line)

save_url() {
    local port="$1" label="$2" url="$3"
    mkdir -p "$SHOES_CONFIG_DIR"
    # Remove any existing entry for this port first
    if [[ -f "$SHOES_URLS" ]]; then
        local tmp; tmp="$(mktemp)"
        grep -v "^${port}|" "$SHOES_URLS" > "$tmp" || true
        mv "$tmp" "$SHOES_URLS"
    fi
    echo "${port}|${label}|${url}" >> "$SHOES_URLS"
}

remove_url() {
    local port="$1"
    [[ -f "$SHOES_URLS" ]] || return
    local tmp; tmp="$(mktemp)"
    grep -v "^${port}|" "$SHOES_URLS" > "$tmp" || true
    mv "$tmp" "$SHOES_URLS"
}

print_url() {
    local port="$1" label="$2" url="$3"
    echo -e "  ${BOLD}${label}${RESET}  →  ${CYAN}${url}${RESET}"
}

# ─── Config helpers ───────────────────────────────────────────────────────────
init_config() {
    mkdir -p "$SHOES_CONFIG_DIR"
    [[ -f "$SHOES_CONFIG" ]] || { echo "# shoes config" > "$SHOES_CONFIG"; info "Created $SHOES_CONFIG"; }
}

add_listener() {
    local block="$1"
    init_config
    echo "" >> "$SHOES_CONFIG"
    echo "$block" >> "$SHOES_CONFIG"
}

list_listeners() {
    header "Configured listeners"
    init_config
    local found=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^-[[:space:]]*address:[[:space:]]*0\.0\.0\.0:([0-9]+) ]]; then
            local port="${BASH_REMATCH[1]}"
            local url_entry=""
            if [[ -f "$SHOES_URLS" ]]; then
                url_entry="$(grep "^${port}|" "$SHOES_URLS" || true)"
            fi
            if [[ -n "$url_entry" ]]; then
                local label url
                label="$(echo "$url_entry" | cut -d'|' -f2)"
                url="$(echo "$url_entry" | cut -d'|' -f3)"
                print_url "$port" "$label" "$url"
            else
                echo "  0.0.0.0:${port}"
            fi
            found=1
        fi
    done < "$SHOES_CONFIG"
    [[ $found -eq 1 ]] || warn "No listeners found in $SHOES_CONFIG"
}

remove_listener() {
    local port="$1"
    init_config
    local pattern="^- address: 0\\.0\\.0\\.0:${port}$"
    local tmpfile; tmpfile="$(mktemp)"
    awk -v pat="$pattern" '
        /^- address:/ {
            if (buffer != "" && !skip) printf "%s", buffer
            skip = ($0 ~ pat)
            buffer = $0 "\n"
            next
        }
        {
            buffer = buffer $0 "\n"
        }
        END {
            if (!skip && buffer != "") printf "%s", buffer
        }
    ' "$SHOES_CONFIG" > "$tmpfile"
    mv "$tmpfile" "$SHOES_CONFIG"
    remove_url "$port"
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
    local block url
    if [[ -z "$user" ]]; then
        block="- address: 0.0.0.0:${port}
  protocol:
    type: http"
        url="http://$(get_server_ip):${port}"
    else
        pass="$(prompt_password)"
        block="- address: 0.0.0.0:${port}
  protocol:
    type: http
    users:
      - username: ${user}
        password: ${pass}"
        url="http://${user}:${pass}@$(get_server_ip):${port}"
    fi
    add_listener "$block"
    save_url "$port" "HTTP" "$url"
    info "HTTP proxy added on port $port."
    print_url "$port" "HTTP" "$url"
}

add_socks5() {
    header "Add SOCKS5 proxy"
    local port; port="$(prompt_port)"
    local user pass
    read -rp "  Username (leave blank for no auth): " user
    local block url
    if [[ -z "$user" ]]; then
        block="- address: 0.0.0.0:${port}
  protocol:
    type: socks5"
        url="socks5://$(get_server_ip):${port}"
    else
        pass="$(prompt_password)"
        block="- address: 0.0.0.0:${port}
  protocol:
    type: socks5
    users:
      - username: ${user}
        password: ${pass}"
        url="socks5://${user}:${pass}@$(get_server_ip):${port}"
    fi
    add_listener "$block"
    save_url "$port" "SOCKS5" "$url"
    info "SOCKS5 proxy added on port $port."
    print_url "$port" "SOCKS5" "$url"
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
    local userinfo; userinfo="$(echo -n "${cipher}:${pass}" | base64 -w0)"
    local url="ss://${userinfo}@$(get_server_ip):${port}"
    save_url "$port" "Shadowsocks" "$url"
    info "Shadowsocks added on port $port."
    print_url "$port" "Shadowsocks" "$url"
}

add_shadowsocks2022() {
    header "Add Shadowsocks 2022 proxy"
    local port; port="$(prompt_port)"
    local cipher
    echo "  Cipher options:"
    echo "    1) 2022-blake3-aes-128-gcm"
    echo "    2) 2022-blake3-aes-256-gcm"
    echo "    3) 2022-blake3-chacha20-ietf-poly1305"
    read -rp "  Cipher [2]: " cipher
    case "${cipher:-2}" in
        1) cipher="2022-blake3-aes-128-gcm" ;;
        2|"") cipher="2022-blake3-aes-256-gcm" ;;
        3) cipher="2022-blake3-chacha20-ietf-poly1305" ;;
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-ietf-poly1305) ;;
        *) warn "Unrecognised cipher; proceeding anyway." ;;
    esac
    info "Generating password for $cipher ..."
    local pass
    pass="$("$SHOES_BIN" generate-shadowsocks-2022-password "$cipher" | awk '/^Password:/{print $2}')"
    info "Generated password: $pass"
    local block="- address: 0.0.0.0:${port}
  protocol:
    type: shadowsocks
    cipher: ${cipher}
    password: ${pass}"
    add_listener "$block"
    local userinfo; userinfo="$(echo -n "${cipher}:${pass}" | base64 -w0)"
    local url="ss://${userinfo}@$(get_server_ip):${port}"
    save_url "$port" "SS2022(${cipher})" "$url"
    info "Shadowsocks 2022 ($cipher) added on port $port."
    print_url "$port" "SS2022(${cipher})" "$url"
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
    local url="trojan://${pass}@$(get_server_ip):${port}"
    save_url "$port" "Trojan" "$url"
    info "Trojan added on port $port."
    print_url "$port" "Trojan" "$url"
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
    local ip; ip="$(get_server_ip)"
    local json; json="$(printf '{"v":"2","ps":"shoes","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","tls":""}' "$ip" "$port" "$uuid")"
    local url="vmess://$(echo -n "$json" | base64 -w0)"
    save_url "$port" "VMess" "$url"
    info "VMess added on port $port."
    print_url "$port" "VMess" "$url"
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
    local url="vless://${uuid}@$(get_server_ip):${port}?security=tls"
    save_url "$port" "VLESS" "$url"
    info "VLESS added on port $port."
    print_url "$port" "VLESS" "$url"
}

add_vless_reality() {
    header "Add VLESS-Reality proxy"
    local port; port="$(prompt_port)"
    local uuid; uuid="$(prompt_uuid)"
    local sni
    read -rp "  SNI hostname (e.g. www.apple.com): " sni
    sni="${sni:-www.apple.com}"

    info "Generating Reality keypair ..."
    local keypair_output private_key public_key
    keypair_output="$("$SHOES_BIN" generate-reality-keypair)"
    private_key="$(echo "$keypair_output" | awk '/private key:/{print $NF}')"
    public_key="$(echo "$keypair_output" | awk '/public key:/{print $NF}')"

    local short_id
    short_id="$(openssl rand -hex 8 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c 16)"

    info "Public Key (share with clients): $public_key"
    info "Short ID   (share with clients): $short_id"

    local block="- address: 0.0.0.0:${port}
  protocol:
    type: tls
    reality_targets:
      \"${sni}\":
        private_key: \"${private_key}\"
        short_ids: [\"${short_id}\", \"\"]
        dest: \"${sni}:443\"
        protocol:
          type: vless
          user_id: ${uuid}
          udp_enabled: true"
    add_listener "$block"

    local ip; ip="$(get_server_ip)"
    local url="vless://${uuid}@${ip}:${port}?security=reality&pbk=${public_key}&sid=${short_id}&sni=${sni}&flow=xtls-rprx-vision&type=tcp"
    save_url "$port" "VLESS-Reality" "$url"
    info "VLESS-Reality added on port $port."
    print_url "$port" "VLESS-Reality" "$url"
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
    local url="hysteria2://${pass}@$(get_server_ip):${port}"
    save_url "$port" "Hysteria2" "$url"
    info "Hysteria2 added on port $port."
    print_url "$port" "Hysteria2" "$url"
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
    local url="tuic://${uuid}:${pass}@$(get_server_ip):${port}"
    save_url "$port" "TUIC v5" "$url"
    info "TUIC v5 added on port $port."
    print_url "$port" "TUIC v5" "$url"
}

add_shadowtls() {
    header "Add ShadowTLS v3 proxy"
    local port; port="$(prompt_port)"
    local pass; pass="$(prompt_password)"
    local sni
    read -rp "  Handshake SNI (real TLS server to impersonate, e.g. www.apple.com): " sni
    sni="${sni:-www.apple.com}"

    # Choose inner Shadowsocks variant
    echo "  Inner protocol:"
    echo "    1) Shadowsocks (chacha20-ietf-poly1305)"
    echo "    2) Shadowsocks 2022 (blake3 ciphers)"
    local inner_choice
    read -rp "  Choice [1]: " inner_choice

    local inner_cipher inner_pass

    case "${inner_choice:-1}" in
        2)
            echo "    Inner SS2022 cipher:"
            echo "      1) 2022-blake3-aes-128-gcm"
            echo "      2) 2022-blake3-aes-256-gcm"
            echo "      3) 2022-blake3-chacha20-ietf-poly1305"
            local cipher_choice
            read -rp "    Cipher [2]: " cipher_choice
            case "${cipher_choice:-2}" in
                1) inner_cipher="2022-blake3-aes-128-gcm" ;;
                2|"") inner_cipher="2022-blake3-aes-256-gcm" ;;
                3) inner_cipher="2022-blake3-chacha20-ietf-poly1305" ;;
                *) inner_cipher="2022-blake3-aes-256-gcm" ;;
            esac
            info "Generating SS2022 password for $inner_cipher ..."
            inner_pass="$("$SHOES_BIN" generate-shadowsocks-2022-password "$inner_cipher" | awk '/^Password:/{print $2}')"
            ;;
        *)
            inner_cipher="chacha20-ietf-poly1305"
            inner_pass="$(openssl rand -base64 16)"
            ;;
    esac

    info "Inner cipher : $inner_cipher"
    info "Inner password: $inner_pass"

    local block="- address: 0.0.0.0:${port}
  protocol:
    type: tls
    shadowtls_targets:
      \"${sni}\":
        password: \"${pass}\"
        handshake:
          address: \"${sni}:443\"
        protocol:
          type: shadowsocks
          cipher: ${inner_cipher}
          password: ${inner_pass}"
    add_listener "$block"

    local ip; ip="$(get_server_ip)"
    local url="shadowtls://v3@${ip}:${port}?password=${pass}&sni=${sni}&inner-ss-pass=${inner_pass}&inner-cipher=${inner_cipher}"
    save_url "$port" "ShadowTLS-v3" "$url"
    info "ShadowTLS v3 added on port $port."
    info "  Outer password : $pass"
    info "  Handshake SNI  : $sni"
    info "  Inner SS cipher: $inner_cipher"
    info "  Inner SS pass  : $inner_pass"
    print_url "$port" "ShadowTLS-v3" "$url"
}

# ─── Add protocol sub-menu ────────────────────────────────────────────────────
menu_add_protocol() {
    header "Add Protocol"
    local options=(
        "HTTP"
        "SOCKS5"
        "Shadowsocks"
        "Shadowsocks 2022"
        "Trojan (TLS)"
        "VMess"
        "VLESS (TLS)"
        "VLESS-Reality"
        "ShadowTLS v3"
        "Hysteria2 (QUIC)"
        "TUIC v5 (QUIC)"
        "Back"
    )
    select choice in "${options[@]}"; do
        case "$choice" in
            "HTTP")              add_http;            break ;;
            "SOCKS5")            add_socks5;          break ;;
            "Shadowsocks")       add_shadowsocks;     break ;;
            "Shadowsocks 2022")  add_shadowsocks2022; break ;;
            "Trojan (TLS)")      add_trojan;          break ;;
            "VMess")             add_vmess;           break ;;
            "VLESS (TLS)")       add_vless;           break ;;
            "VLESS-Reality")    add_vless_reality;   break ;;
            "ShadowTLS v3")     add_shadowtls;       break ;;
            "Hysteria2 (QUIC)")  add_hysteria2;       break ;;
            "TUIC v5 (QUIC)")    add_tuic;            break ;;
            "Back")              break ;;
            *) warn "Invalid selection." ;;
        esac
    done
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
            "Uninstall"
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
                "Uninstall")
                    uninstall_shoes
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
