#!/usr/bin/env bash
# panel.sh - shoes proxy management panel for Debian/Ubuntu VPS
set -euo pipefail

SHOES_VERSION="v0.2.7"
SHOES_BIN="/usr/local/bin/shoes"
SHOES_CONFIG_DIR="/etc/shoes"
SHOES_BASE_CONFIG="${SHOES_CONFIG_DIR}/base.yaml"
SHOES_LISTENER_DIR="${SHOES_CONFIG_DIR}/listeners.d"
SHOES_CONFIG="${SHOES_CONFIG_DIR}/config.yaml"
SHOES_URLS="${SHOES_CONFIG_DIR}/urls.conf"
SHOES_CERT_DIR="${SHOES_CONFIG_DIR}/certs"
SHOES_CERT_INDEX="${SHOES_CERT_DIR}/index.txt"
SHADOWTLS_META_DIR="${SHOES_CONFIG_DIR}/shadowtls.d"
SHADOWTLS_BIN="/usr/local/bin/shadow-tls"
SHADOWTLS_INTERNAL_LABEL="__shadowtls_backend__"
FIREWALL_RULES="${SHOES_CONFIG_DIR}/udp-blocks.conf"
FIREWALL_NFT_FILE="${SHOES_CONFIG_DIR}/proxy-panel-firewall.nft"
NFTABLES_MAIN_CONF="/etc/nftables.conf"
SHOES_SERVICE="/etc/systemd/system/shoes.service"
PANEL_MARKER="# managed-by-proxy-panel"
GITHUB_RELEASE_BASE="https://github.com/cfal/shoes/releases/download/${SHOES_VERSION}"
ACME_SH_BIN="/root/.acme.sh/acme.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info() { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[x]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}$*${RESET}\n"; }

if [[ ! -t 0 ]]; then
    exec < /dev/tty 2>/dev/null || {
        echo "No TTY available. Please run:"
        echo "  curl -fsSL https://raw.githubusercontent.com/utada1stlove/proxy_panel/main/panel.sh -o /tmp/panel.sh && bash /tmp/panel.sh"
        exit 1
    }
fi

require_root() {
    [[ $EUID -eq 0 ]] || { error "This script must be run as root."; exit 1; }
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        *) error "Unsupported architecture: $machine"; exit 1 ;;
    esac
}

shoes_installed() {
    [[ -x "$SHOES_BIN" ]]
}

get_server_ip() {
    curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s4 --max-time 5 icanhazip.com 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

b64enc() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

b64urlenc() {
    printf '%s' "$1" | base64 | tr -d '\n=' | tr '+/' '-_'
}

b64stdenc() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

rawurlencode() {
    local input="$1"
    local output=""
    local i char hex

    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) output+="$char" ;;
            *)
                printf -v hex '%%%02X' "'$char"
                output+="$hex"
                ;;
        esac
    done

    printf '%s\n' "$output"
}

ss_userinfo_uri() {
    local cipher="$1" pass="$2"

    if [[ "$cipher" == 2022-* ]]; then
        printf '%s:%s\n' "$(rawurlencode "$cipher")" "$(rawurlencode "$pass")"
    else
        b64urlenc "${cipher}:${pass}"
        printf '\n'
    fi
}

internal_url_label() {
    [[ "$1" == "${SHADOWTLS_INTERNAL_LABEL}"* ]]
}

ensure_directory() {
    mkdir -p "$1"
}

ensure_config_dirs() {
    ensure_directory "$SHOES_CONFIG_DIR"
    ensure_directory "$SHOES_LISTENER_DIR"
    ensure_directory "$SHOES_CERT_DIR"
    ensure_directory "$SHADOWTLS_META_DIR"
    [[ -f "$SHOES_URLS" ]] || : > "$SHOES_URLS"
    [[ -f "$SHOES_CERT_INDEX" ]] || : > "$SHOES_CERT_INDEX"
    [[ -f "$FIREWALL_RULES" ]] || : > "$FIREWALL_RULES"
}

normalize_name() {
    local input="$1"
    input="${input,,}"
    input="${input//[^a-z0-9._-]/-}"
    input="${input#-}"
    input="${input%-}"
    printf '%s\n' "${input:-item}"
}

is_ipv4_literal() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_port_spec() {
    local value="$1" start end
    [[ "$value" =~ ^[0-9]+(-[0-9]+)?$ ]] || return 1
    if [[ "$value" == *-* ]]; then
        start="${value%-*}"
        end="${value#*-}"
        (( start >= 1 && start <= 65535 && end >= start && end <= 65535 ))
    else
        (( value >= 1 && value <= 65535 ))
    fi
}

prompt_port_spec() {
    local port_spec
    while true; do
        read -rp "  UDP port or range (e.g. 443 or 8000-8099): " port_spec
        validate_port_spec "$port_spec" && {
            printf '%s\n' "$port_spec"
            return 0
        }
        warn "Invalid port or range."
    done
}

find_acme_sh() {
    local candidate
    for candidate in "$ACME_SH_BIN" /usr/local/bin/acme.sh "$HOME/.acme.sh/acme.sh"; do
        [[ -x "$candidate" ]] && {
            printf '%s\n' "$candidate"
            return 0
        }
    done
    return 1
}

prompt_default_yes() {
    local prompt="$1" reply
    read -rp "$prompt [Y/n]: " reply
    [[ -z "${reply:-}" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

prompt_default_no() {
    local prompt="$1" reply
    read -rp "$prompt [y/N]: " reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

join_by() {
    local separator="$1"
    shift || true
    local item output=""

    for item in "$@"; do
        if [[ -n "$output" ]]; then
            output+="${separator}"
        fi
        output+="${item}"
    done

    printf '%s\n' "$output"
}

repeat_char() {
    local char="$1" count="$2" output
    printf -v output '%*s' "$count" ''
    printf '%s' "${output// /$char}"
}

truncate_text() {
    local text="$1" width="$2"
    if (( width <= 3 )); then
        printf '%.*s' "$width" "$text"
    elif (( ${#text} > width )); then
        printf '%s...' "${text:0:width-3}"
    else
        printf '%s' "$text"
    fi
}

pad_cell() {
    local text="$1" width="$2"
    text="$(truncate_text "$text" "$width")"
    printf '%-*s' "$width" "$text"
}

wrap_text_lines() {
    local text="$1" width="$2"

    if (( width <= 0 )); then
        printf '%s\n' "$text"
        return 0
    fi

    if [[ -z "$text" ]]; then
        printf '\n'
        return 0
    fi

    while [[ -n "$text" ]]; do
        printf '%s\n' "${text:0:width}"
        text="${text:width}"
    done
}

wrap_share_base_lines() {
    local base="$1" width="$2"
    local left right

    if [[ "$base" == *'@'* && "$base" == *'://'* ]]; then
        left="${base%@*}"
        right="@${base#*@}"

        if (( ${#left} <= width )); then
            printf '%s\n' "$left"
            wrap_text_lines "$right" "$width"
            return 0
        fi
    fi

    wrap_text_lines "$base" "$width"
}

wrap_share_url_lines() {
    local url="$1" width="$2"
    local base query fragment item prefix
    local -a query_items

    if [[ -z "$url" ]]; then
        printf '\n'
        return 0
    fi

    base="$url"
    fragment=""
    query=""

    if [[ "$base" == *'#'* ]]; then
        fragment="#${base#*#}"
        base="${base%%#*}"
    fi

    if [[ "$base" == *'?'* ]]; then
        query="${base#*\?}"
        base="${base%%\?*}"
    fi

    wrap_share_base_lines "$base" "$width"

    if [[ -n "$query" ]]; then
        IFS='&' read -r -a query_items <<< "$query"
        prefix='?'
        for item in "${query_items[@]}"; do
            wrap_text_lines "${prefix}${item}" "$width"
            prefix='&'
        done
    fi

    if [[ -n "$fragment" ]]; then
        wrap_text_lines "$fragment" "$width"
    fi
}

share_scheme() {
    local url="$1"
    if [[ "$url" =~ ^([^:]+):// ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "raw"
    fi
}

share_endpoint() {
    local url="$1" base scheme
    scheme="$(share_scheme "$url")"

    if [[ "$scheme" == "vmess" ]]; then
        printf '%s\n' "encoded payload"
        return 0
    fi

    base="${url%%\?*}"
    base="${base%%#*}"
    base="${base#*://}"

    if [[ "$base" == *@* ]]; then
        base="${base#*@}"
    fi

    printf '%s\n' "${base:-n/a}"
}

shadowtls_shadowrocket_param() {
    local address="$1" port="$2" sni="$3" password="$4"
    local json

    json="$(printf '{"version":"3","password":"%s","host":"%s","port":"%s","address":"%s"}' \
        "$password" "$sni" "$port" "$address")"
    b64stdenc "$json"
    printf '\n'
}

print_share_card() {
    local port="$1" label="$2" url="$3" show_qr="${4:-false}"
    local cols line_width divider scheme endpoint

    cols="$(terminal_columns)"
    line_width=$((cols - 2))
    (( line_width < 72 )) && line_width=72
    divider="$(repeat_char '━' "$line_width")"
    scheme="$(share_scheme "$url")"
    endpoint="$(share_endpoint "$url")"

    printf '%b%s%b\n' "${CYAN}" "$divider" "${RESET}"
    printf '%bShare%b  %s  %b(port %s)%b\n' "${BOLD}${CYAN}" "${RESET}" "$label" "${YELLOW}" "$port" "${RESET}"
    printf '  %bScheme%b   %s\n' "${BOLD}" "${RESET}" "$scheme"
    printf '  %bEndpoint%b %s\n' "${BOLD}" "${RESET}" "$endpoint"
    printf '  %bCopy URL%b\n' "${BOLD}" "${RESET}"
    printf '    %s\n' "$url"

    if [[ "$show_qr" == "true" && -n "$url" && "$(share_scheme "$url")" != "raw" ]]; then
        if command_exists qrencode; then
            printf '  %bQR%b\n' "${BOLD}" "${RESET}"
            qrencode -t UTF8 <<<"$url"
        fi
    fi
}

print_share_details() {
    local rows="$1" show_qr="${2:-false}"
    local row port label url
    local emitted=0

    header "Share Details"
    while IFS= read -r row; do
        [[ -n "${row:-}" ]] || continue
        IFS=$'\t' read -r port label url <<< "$row"
        print_share_card "$port" "$label" "$url" "$show_qr"
        emitted=1
    done <<< "$rows"

    (( emitted == 1 )) && printf '%b%s%b\n' "${CYAN}" "$(repeat_char '━' "$(terminal_columns)")" "${RESET}"
}

terminal_columns() {
    local cols
    cols="$(tput cols 2>/dev/null || printf '120')"
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=120
    (( cols < 90 )) && cols=90
    printf '%s\n' "$cols"
}

ensure_fzf_ready() {
    if command_exists fzf; then
        return 0
    fi

    warn "fzf is required for Tab multi-select."
    prompt_default_yes "  Install fzf now?" || return 1

    if command_exists apt-get; then
        apt-get update
        apt-get install -y fzf
    else
        error "Automatic fzf installation currently supports apt-get only."
        return 1
    fi
}

ensure_nft_ready() {
    if command_exists nft; then
        return 0
    fi

    warn "nftables is not installed."
    prompt_default_yes "  Install nftables now?" || return 1

    if command_exists apt-get; then
        apt-get update
        apt-get install -y nftables
    else
        error "Automatic nftables installation currently supports apt-get only."
        return 1
    fi

    command_exists systemctl && systemctl enable --now nftables >/dev/null 2>&1 || true
}

firewall_rule_exists() {
    local direction="$1" port_spec="$2"
    grep -Fxq "${direction}|${port_spec}" "$FIREWALL_RULES" 2>/dev/null
}

render_firewall_rules() {
    local tmp direction port_spec

    ensure_config_dirs
    tmp="$(mktemp)"

    {
        cat <<'EOF'
table inet proxy_panel {
  chain input {
    type filter hook input priority 0; policy accept;
EOF

        while IFS='|' read -r direction port_spec; do
            [[ -n "${direction:-}" && -n "${port_spec:-}" ]] || continue
            case "$direction" in
                input|both)
                    printf '    udp dport %s counter drop comment "proxy-panel udp input %s"\n' "$port_spec" "$port_spec"
                    ;;
            esac
        done <"$FIREWALL_RULES"

        cat <<'EOF'
  }

  chain output {
    type filter hook output priority 0; policy accept;
EOF

        while IFS='|' read -r direction port_spec; do
            [[ -n "${direction:-}" && -n "${port_spec:-}" ]] || continue
            case "$direction" in
                output|both)
                    printf '    udp dport %s counter drop comment "proxy-panel udp output %s"\n' "$port_spec" "$port_spec"
                    ;;
            esac
        done <"$FIREWALL_RULES"

        cat <<'EOF'
  }
}
EOF
    } >"$tmp"

    mv "$tmp" "$FIREWALL_NFT_FILE"
}

ensure_firewall_persistence() {
    local include_line="include \"${FIREWALL_NFT_FILE}\""

    if [[ ! -f "$NFTABLES_MAIN_CONF" ]]; then
        cat >"$NFTABLES_MAIN_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

${include_line}
EOF
        return 0
    fi

    grep -Fqx "$include_line" "$NFTABLES_MAIN_CONF" || printf '\n%s\n' "$include_line" >>"$NFTABLES_MAIN_CONF"
}

apply_firewall_rules() {
    ensure_nft_ready || return 1
    render_firewall_rules
    nft delete table inet proxy_panel 2>/dev/null || true
    nft -f "$FIREWALL_NFT_FILE"
    ensure_firewall_persistence
    command_exists systemctl && systemctl enable --now nftables >/dev/null 2>&1 || true
}

add_udp_block() {
    local port_spec="$1" direction="$2" backup

    ensure_config_dirs
    firewall_rule_exists "$direction" "$port_spec" && {
        warn "That UDP block rule already exists."
        return 1
    }

    backup="$(mktemp)"
    cp "$FIREWALL_RULES" "$backup"
    printf '%s|%s\n' "$direction" "$port_spec" >>"$FIREWALL_RULES"

    if ! apply_firewall_rules; then
        mv "$backup" "$FIREWALL_RULES"
        render_firewall_rules
        return 1
    fi

    rm -f "$backup"
}

remove_udp_block() {
    local direction="$1" port_spec="$2" backup tmp

    firewall_rule_exists "$direction" "$port_spec" || {
        warn "That UDP block rule does not exist."
        return 1
    }

    backup="$(mktemp)"
    tmp="$(mktemp)"
    cp "$FIREWALL_RULES" "$backup"
    grep -Fvx "${direction}|${port_spec}" "$FIREWALL_RULES" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$FIREWALL_RULES"

    if ! apply_firewall_rules; then
        mv "$backup" "$FIREWALL_RULES"
        render_firewall_rules
        return 1
    fi

    rm -f "$backup"
}

list_udp_blocks() {
    local index=1 direction port_spec

    header "Managed UDP blocks"
    ensure_config_dirs

    while IFS='|' read -r direction port_spec; do
        [[ -n "${direction:-}" && -n "${port_spec:-}" ]] || continue
        printf '  %d. UDP %s  [%s]\n' "$index" "$port_spec" "$direction"
        ((index++))
    done <"$FIREWALL_RULES"

    if (( index == 1 )); then
        warn "No managed UDP block rules."
    fi
}

cert_dir_for_name() {
    printf '%s/%s\n' "$SHOES_CERT_DIR" "$(normalize_name "$1")"
}

write_cert_index_entry() {
    local name="$1" cert_type="$2" cert_path="$3" key_path="$4"
    local tmp

    ensure_config_dirs
    tmp="$(mktemp)"
    grep -Fv "|${cert_path}|${key_path}" "$SHOES_CERT_INDEX" >"$tmp" 2>/dev/null || true
    printf '%s|%s|%s|%s\n' "$name" "$cert_type" "$cert_path" "$key_path" >>"$tmp"
    mv "$tmp" "$SHOES_CERT_INDEX"
}

cert_name_from_path() {
    local cert_path="$1"
    awk -F'|' -v cert_path="$cert_path" '$3 == cert_path { print $1; exit }' "$SHOES_CERT_INDEX" 2>/dev/null || true
}

cert_type_from_path() {
    local cert_path="$1"
    awk -F'|' -v cert_path="$cert_path" '$3 == cert_path { print $2; exit }' "$SHOES_CERT_INDEX" 2>/dev/null || true
}

create_self_signed_cert() {
    local name="$1" cert_dir cert_path key_path san_line tmp_conf

    command_exists openssl || { error "openssl is required."; return 1; }

    cert_dir="$(cert_dir_for_name "$name")"
    cert_path="${cert_dir}/fullchain.pem"
    key_path="${cert_dir}/privkey.pem"
    ensure_directory "$cert_dir"
    tmp_conf="$(mktemp)"

    if is_ipv4_literal "$name"; then
        san_line="IP.1 = ${name}"
    else
        san_line="DNS.1 = ${name}"
    fi

    cat >"$tmp_conf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${name}

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
${san_line}
EOF

    if ! openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$key_path" \
        -out "$cert_path" \
        -days 825 \
        -config "$tmp_conf" >/dev/null 2>&1; then
        rm -f "$tmp_conf" "$cert_path" "$key_path"
        error "Failed to create the self-signed certificate."
        return 1
    fi
    chmod 600 "$key_path"
    rm -f "$tmp_conf"

    write_cert_index_entry "$name" "self-signed" "$cert_path" "$key_path"
    printf '%s\n%s\n' "$cert_path" "$key_path"
}

ensure_acme_sh() {
    local email="$1" acme_sh

    if acme_sh="$(find_acme_sh)"; then
        printf '%s\n' "$acme_sh"
        return 0
    fi

    info "Installing acme.sh ..." >&2
    curl -fsSL https://get.acme.sh | sh -s email="$email" >/dev/null
    acme_sh="$(find_acme_sh)" || {
        error "Failed to install acme.sh."
        return 1
    }
    printf '%s\n' "$acme_sh"
}

port_80_in_use() {
    ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -Eq '(^|:|\])80$'
}

issue_domain_cert() {
    local domain="$1" email="$2" acme_sh cert_dir cert_path key_path
    local -a stopped_services=()
    local service

    command_exists openssl || { error "openssl is required."; return 1; }
    command_exists curl || { error "curl is required."; return 1; }

    acme_sh="$(ensure_acme_sh "$email")" || return 1
    cert_dir="$(cert_dir_for_name "$domain")"
    cert_path="${cert_dir}/fullchain.pem"
    key_path="${cert_dir}/privkey.pem"
    ensure_directory "$cert_dir"

    if port_80_in_use; then
        warn "TCP/80 is currently in use. ACME standalone mode needs that port." >&2
        if prompt_default_yes "  Try stopping nginx/apache2/caddy/shoes temporarily?"; then
            for service in nginx apache2 caddy shoes; do
                if command_exists systemctl && systemctl is-active --quiet "$service" 2>/dev/null; then
                    systemctl stop "$service"
                    stopped_services+=("$service")
                fi
            done
        fi
    fi

    if port_80_in_use; then
        error "Port 80 is still busy. Free it and retry the certificate request."
        for service in "${stopped_services[@]}"; do
            command_exists systemctl && systemctl start "$service" >/dev/null 2>&1 || true
        done
        return 1
    fi

    info "Issuing Let's Encrypt certificate for ${domain} ..." >&2
    if ! "$acme_sh" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt >&2; then
        error "Certificate issuance failed."
        for service in "${stopped_services[@]}"; do
            command_exists systemctl && systemctl start "$service" >/dev/null 2>&1 || true
        done
        return 1
    fi

    if ! "$acme_sh" --install-cert -d "$domain" \
        --key-file "$key_path" \
        --fullchain-file "$cert_path" \
        --reloadcmd "chmod 600 '$key_path'; systemctl restart shoes >/dev/null 2>&1 || true" >/dev/null; then
        error "Certificate issuance succeeded, but install-cert failed."
        for service in "${stopped_services[@]}"; do
            command_exists systemctl && systemctl start "$service" >/dev/null 2>&1 || true
        done
        return 1
    fi

    chmod 600 "$key_path"
    write_cert_index_entry "$domain" "acme" "$cert_path" "$key_path"

    for service in "${stopped_services[@]}"; do
        command_exists systemctl && systemctl start "$service" >/dev/null 2>&1 || true
    done

    printf '%s\n%s\n' "$cert_path" "$key_path"
}

certificate_common_name() {
    local cert_path="$1"
    openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p'
}

certificate_summary() {
    local cert_path="$1"
    local subject issuer expiry

    subject="$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    issuer="$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    expiry="$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    printf '%s\n%s\n%s\n' "$subject" "$issuer" "$expiry"
}

select_managed_certificate() {
    local -a cert_paths=() labels=()
    local line name cert_type cert_path key_path index selection

    ensure_config_dirs

    while IFS='|' read -r name cert_type cert_path key_path; do
        [[ -f "${cert_path:-}" && -f "${key_path:-}" ]] || continue
        cert_paths+=("$cert_path|$key_path")
        labels+=("${name} [${cert_type}]")
    done <"$SHOES_CERT_INDEX"

    [[ ${#cert_paths[@]} -gt 0 ]] || {
        warn "No managed certificates available." >&2
        return 1
    }

    header "Managed certificates" >&2
    for index in "${!labels[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${labels[$index]}" >&2
    done

    while true; do
        read -rp "  Select certificate: " selection
        [[ "$selection" =~ ^[0-9]+$ ]] || { warn "Invalid selection." >&2; continue; }
        (( selection >= 1 && selection <= ${#cert_paths[@]} )) || { warn "Invalid selection." >&2; continue; }
        printf '%s\n' "${cert_paths[$((selection - 1))]}"
        return 0
    done
}

list_managed_certificates() {
    local name cert_type cert_path key_path
    local -a summary
    local found=0

    header "Managed certificates"
    ensure_config_dirs

    while IFS='|' read -r name cert_type cert_path key_path; do
        [[ -f "${cert_path:-}" && -f "${key_path:-}" ]] || continue
        found=1
        mapfile -t summary < <(certificate_summary "$cert_path")
        printf '  %s [%s]\n' "$name" "$cert_type"
        printf '    cert: %s\n' "$cert_path"
        printf '    key : %s\n' "$key_path"
        [[ -n "${summary[0]:-}" ]] && printf '    %s\n' "${summary[0]}"
        [[ -n "${summary[1]:-}" ]] && printf '    %s\n' "${summary[1]}"
        [[ -n "${summary[2]:-}" ]] && printf '    expires: %s\n' "${summary[2]}"
    done <"$SHOES_CERT_INDEX"

    (( found == 1 )) || warn "No managed certificates."
}

config_is_managed() {
    [[ -f "$SHOES_CONFIG" ]] && grep -Fq "$PANEL_MARKER" "$SHOES_CONFIG"
}

base_config_has_content() {
    [[ -f "$SHOES_BASE_CONFIG" ]] && grep -Eq '^[[:space:]]*-[[:space:]]|^[[:space:]]*[a-zA-Z0-9_-]+:' "$SHOES_BASE_CONFIG"
}

migrate_legacy_config() {
    ensure_config_dirs

    if [[ -f "$SHOES_CONFIG" && ! -f "$SHOES_BASE_CONFIG" ]] && ! config_is_managed; then
        mv "$SHOES_CONFIG" "$SHOES_BASE_CONFIG"
        info "Moved existing config to $SHOES_BASE_CONFIG"
    fi
}

render_config() {
    local tmp
    tmp="$(mktemp)"

    {
        printf '%s\n' "$PANEL_MARKER"
        printf '%s\n\n' "# Generated from base.yaml and listeners.d fragments."

        if [[ -f "$SHOES_BASE_CONFIG" ]]; then
            sed '/^[[:space:]]*$/N;/^\n$/D' "$SHOES_BASE_CONFIG"
            printf '\n'
        fi

        find "$SHOES_LISTENER_DIR" -maxdepth 1 -type f -name '*.yaml' | sort | while IFS= read -r file; do
            sed '/^[[:space:]]*$/N;/^\n$/D' "$file"
            printf '\n'
        done
    } >"$tmp"

    mv "$tmp" "$SHOES_CONFIG"
}

validate_config() {
    shoes_installed || return 0
    "$SHOES_BIN" --dry-run "$SHOES_CONFIG" >/dev/null
}

init_config() {
    migrate_legacy_config
    render_config
}

listener_file_for_port() {
    printf '%s/%05d.yaml\n' "$SHOES_LISTENER_DIR" "$1"
}

shadowtls_meta_file_for_port() {
    printf '%s/%05d.conf\n' "$SHADOWTLS_META_DIR" "$1"
}

shadowtls_service_name_for_port() {
    printf 'shadowtls-ss-%s\n' "$1"
}

shadowtls_service_file_for_port() {
    printf '/etc/systemd/system/%s.service\n' "$(shadowtls_service_name_for_port "$1")"
}

shadowtls_meta_value() {
    local port="$1" key="$2"
    local file
    file="$(shadowtls_meta_file_for_port "$port")"
    [[ -f "$file" ]] || return 1
    awk -F'|' -v key="$key" '$1 == key { print substr($0, length($1) + 2); exit }' "$file"
}

write_shadowtls_meta() {
    local listen_port="$1" backend_port="$2" share_host="$3" sni="$4" stls_password="$5" inner_cipher="$6" inner_pass="$7"
    local file
    file="$(shadowtls_meta_file_for_port "$listen_port")"
    cat >"$file" <<EOF
mode|standalone
listen_port|${listen_port}
backend_port|${backend_port}
share_host|${share_host}
sni|${sni}
stls_password|${stls_password}
inner_cipher|${inner_cipher}
inner_pass|${inner_pass}
service_name|$(shadowtls_service_name_for_port "$listen_port")
EOF
}

shadowtls_meta_exists() {
    [[ -f "$(shadowtls_meta_file_for_port "$1")" ]]
}

port_in_use() {
    [[ -f "$(listener_file_for_port "$1")" || -f "$(shadowtls_meta_file_for_port "$1")" ]]
}

save_url() {
    local port="$1" label="$2" url="$3"
    save_url_entries "$port" "$(url_entry "$label" "$url")"
}

url_entry() {
    local label="$1" url="$2"
    printf '%s|%s\n' "$label" "$url"
}

append_url_entry() {
    local entries="$1" label="$2" url="$3"
    if [[ -n "$entries" ]]; then
        printf '%s\n%s|%s\n' "$entries" "$label" "$url"
    else
        url_entry "$label" "$url"
    fi
}

save_url_entries() {
    local port="$1" entries="$2"
    local tmp entry_label entry_url

    ensure_config_dirs
    tmp="$(mktemp)"
    grep -v "^${port}|" "$SHOES_URLS" >"$tmp" 2>/dev/null || true
    while IFS='|' read -r entry_label entry_url; do
        [[ -n "${entry_label:-}" && -n "${entry_url:-}" ]] || continue
        printf '%s|%s|%s\n' "$port" "$entry_label" "$entry_url" >>"$tmp"
    done <<< "$entries"
    mv "$tmp" "$SHOES_URLS"
}

remove_url() {
    local port="$1"
    local tmp

    [[ -f "$SHOES_URLS" ]] || return 0
    tmp="$(mktemp)"
    grep -v "^${port}|" "$SHOES_URLS" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$SHOES_URLS"
}

get_url_label() {
    local port="$1"
    awk -F'|' -v port="$port" '$1 == port { print $2; exit }' "$SHOES_URLS" 2>/dev/null || true
}

get_url_value() {
    local port="$1"
    awk -F'|' -v port="$port" '$1 == port { print $3; exit }' "$SHOES_URLS" 2>/dev/null || true
}

get_url_entries() {
    local port="$1"
    awk -F'|' -v port="$port" '$1 == port { print $2 "|" $3 }' "$SHOES_URLS" 2>/dev/null || true
}

write_listener_file() {
    local port="$1" label="$2" block="$3"
    local file

    file="$(listener_file_for_port "$port")"
    {
        printf '# label: %s\n' "$label"
        printf '# port: %s\n' "$port"
        printf '%s\n' "$block"
    } >"$file"
}

reload_runtime_config() {
    render_config
    if ! validate_config; then
        warn "Generated config failed validation."
        return 1
    fi
    return 0
}

restart_if_running() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet shoes 2>/dev/null; then
        service_action restart
    fi
}

add_listener() {
    local port="$1" label="$2" block="$3" url_entries="$4"
    local file backup_file backup_urls

    init_config
    file="$(listener_file_for_port "$port")"
    backup_file=""
    backup_urls="$(mktemp)"
    cp "$SHOES_URLS" "$backup_urls" 2>/dev/null || : >"$backup_urls"

    if [[ -f "$file" ]]; then
        warn "Port $port already exists."
        rm -f "$backup_urls"
        return 1
    fi

    write_listener_file "$port" "$label" "$block"
    save_url_entries "$port" "$url_entries"

    if ! reload_runtime_config; then
        rm -f "$file"
        mv "$backup_urls" "$SHOES_URLS"
        render_config
        return 1
    fi

    rm -f "$backup_urls" "$backup_file"
    restart_if_running
}

remove_shadowtls_standalone() {
    local port="$1" skip_restart="${2:-false}"
    local backend_port meta_file

    meta_file="$(shadowtls_meta_file_for_port "$port")"
    [[ -f "$meta_file" ]] || { warn "No managed standalone ShadowTLS found on port $port."; return 1; }
    backend_port="$(shadowtls_meta_value "$port" "backend_port" || true)"

    stop_shadowtls_service "$port"
    rm -f "$meta_file"
    remove_url "$port"

    if [[ -n "${backend_port:-}" && -f "$(listener_file_for_port "$backend_port")" ]]; then
        remove_listener "$backend_port" true || return 1
    fi

    info "Removed standalone ShadowTLS on port $port."
    [[ "$skip_restart" == "true" ]] || restart_if_running
}

remove_listener() {
    local port="$1" skip_restart="${2:-false}"
    local file backup_file backup_urls

    if shadowtls_meta_exists "$port"; then
        remove_shadowtls_standalone "$port" "$skip_restart"
        return $?
    fi

    init_config
    file="$(listener_file_for_port "$port")"
    [[ -f "$file" ]] || { warn "No managed listener found on port $port."; return 1; }

    backup_file="$(mktemp)"
    backup_urls="$(mktemp)"
    cp "$file" "$backup_file"
    cp "$SHOES_URLS" "$backup_urls" 2>/dev/null || : >"$backup_urls"

    rm -f "$file"
    remove_url "$port"

    if ! reload_runtime_config; then
        mv "$backup_file" "$file"
        mv "$backup_urls" "$SHOES_URLS"
        render_config
        return 1
    fi

    rm -f "$backup_file" "$backup_urls"
    info "Removed listener on port $port."
    [[ "$skip_restart" == "true" ]] || restart_if_running
}

print_url() {
    local label="$1" url="$2"
    local port="${label##*-}"
    [[ "$port" =~ ^[0-9]+$ ]] || port="n/a"
    print_share_card "$port" "$label" "$url" "true"
}

print_url_entries() {
    local port="$1" entries="$2" show_qr="${3:-true}"
    local label url

    while IFS='|' read -r label url; do
        [[ -n "${label:-}" && -n "${url:-}" ]] || continue
        print_share_card "$port" "$label" "$url" "$show_qr"
    done <<< "$entries"
}

listener_detail_rows() {
    local file port entries label url
    local emitted internal_only

    init_config

    for file in "$SHOES_LISTENER_DIR"/*.yaml; do
        [[ -e "$file" ]] || continue
        port="$(basename "$file" .yaml)"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        port="$((10#$port))"
        entries="$(get_url_entries "$port")"
        emitted=0
        internal_only=0

        while IFS='|' read -r label url; do
            [[ -n "${label:-}" && -n "${url:-}" ]] || continue
            if internal_url_label "$label"; then
                internal_only=1
                continue
            fi
            printf '%s\t%s\t%s\n' "$port" "$label" "$url"
            emitted=1
        done <<< "$entries"

        if (( emitted == 0 && internal_only == 0 )); then
            printf '%s\t%s\t%s\n' "$port" "listener-${port}" "0.0.0.0:${port}"
        fi
    done

    for file in "$SHADOWTLS_META_DIR"/*.conf; do
        [[ -e "$file" ]] || continue
        port="$(basename "$file" .conf)"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        port="$((10#$port))"
        entries="$(get_url_entries "$port")"

        while IFS='|' read -r label url; do
            [[ -n "${label:-}" && -n "${url:-}" ]] || continue
            internal_url_label "$label" && continue
            printf '%s\t%s\t%s\n' "$port" "$label" "$url"
        done <<< "$entries"
    done
}

listener_select_rows() {
    local file port entries label url
    local -a labels urls
    local internal_only

    init_config

    for file in "$SHOES_LISTENER_DIR"/*.yaml; do
        [[ -e "$file" ]] || continue
        port="$(basename "$file" .yaml)"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        port="$((10#$port))"
        entries="$(get_url_entries "$port")"
        labels=()
        urls=()
        internal_only=0

        while IFS='|' read -r label url; do
            [[ -n "${label:-}" && -n "${url:-}" ]] || continue
            if internal_url_label "$label"; then
                internal_only=1
                continue
            fi
            labels+=("$label")
            urls+=("$url")
        done <<< "$entries"

        if (( ${#labels[@]} == 0 && internal_only == 0 )); then
            printf '%s\t%s\t%s\n' "$port" "listener-${port}" "0.0.0.0:${port}"
        elif (( ${#labels[@]} > 0 )); then
            printf '%s\t%s\t%s\n' "$port" "$(join_by ', ' "${labels[@]}")" "$(join_by ' || ' "${urls[@]}")"
        fi
    done

    for file in "$SHADOWTLS_META_DIR"/*.conf; do
        [[ -e "$file" ]] || continue
        port="$(basename "$file" .conf)"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        port="$((10#$port))"
        entries="$(get_url_entries "$port")"
        labels=()
        urls=()

        while IFS='|' read -r label url; do
            [[ -n "${label:-}" && -n "${url:-}" ]] || continue
            internal_url_label "$label" && continue
            labels+=("$label")
            urls+=("$url")
        done <<< "$entries"

        if (( ${#labels[@]} > 0 )); then
            printf '%s\t%s\t%s\n' "$port" "$(join_by ', ' "${labels[@]}")" "$(join_by ' || ' "${urls[@]}")"
        fi
    done
}

share_catalog_rows() {
    local row port label url scheme endpoint

    while IFS= read -r row; do
        [[ -n "${row:-}" ]] || continue
        IFS=$'\t' read -r port label url <<< "$row"
        scheme="$(share_scheme "$url")"
        endpoint="$(share_endpoint "$url")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$port" "$label" "$scheme" "$endpoint" "$url"
    done < <(listener_detail_rows)
}

select_share_rows_prompt() {
    local rows="$1" selection token index
    local -a row_list selected_rows

    mapfile -t row_list <<< "$rows"
    [[ ${#row_list[@]} -gt 0 ]] || return 1

    header "Share links"
    for index in "${!row_list[@]}"; do
        IFS=$'\t' read -r port label scheme endpoint url <<< "${row_list[$index]}"
        printf '  %d) [%s] %s  (%s, %s)\n' "$((index + 1))" "$port" "$label" "$scheme" "$endpoint"
    done

    read -rp "  Select share # (comma-separated): " selection
    [[ -n "${selection// }" ]] || return 1

    IFS=',' read -r -a tokens <<< "$selection"
    for token in "${tokens[@]}"; do
        token="${token//[[:space:]]/}"
        [[ "$token" =~ ^[0-9]+$ ]] || { warn "Invalid selection: $token"; return 1; }
        (( token >= 1 && token <= ${#row_list[@]} )) || { warn "Invalid selection: $token"; return 1; }
        selected_rows+=("${row_list[$((token - 1))]}")
    done

    for row in "${selected_rows[@]}"; do
        IFS=$'\t' read -r port label scheme endpoint url <<< "$row"
        printf '%s\t%s\t%s\n' "$port" "$label" "$url"
    done
}

select_share_rows_multi() {
    local rows="$1" selection

    if command_exists fzf; then
        selection="$(printf '%s\n' "$rows" | fzf \
            --multi \
            --delimiter=$'\t' \
            --with-nth=1,2,3,4 \
            --bind='tab:toggle+down,btab:toggle+up' \
            --prompt='Share links > ' \
            --header=$'TAB mark/unmark | ENTER show selected shares | ESC cancel' \
            --preview-window='down,70%,wrap' \
            --preview='printf "Port: %s\nLabel: %s\nScheme: %s\nEndpoint: %s\n\nCopy URL:\n%s\n" {1} {2} {3} {4} {5}' \
        )" || return 1
        [[ -n "$selection" ]] || return 1
        printf '%s\n' "$selection" | awk -F'\t' '{print $1 "\t" $2 "\t" $5}'
        return 0
    fi

    warn "fzf is not installed. Falling back to numbered selection."
    select_share_rows_prompt "$rows"
}

print_listener_table() {
    local rows="$1"
    local cols port_w label_w url_w
    local top_border header_row mid_border bottom_border
    local idx row port label url max_lines line_idx
    local -a row_list port_lines label_lines url_lines

    cols="$(terminal_columns)"
    port_w=6
    label_w=26
    url_w=$((cols - port_w - label_w - 10))
    (( url_w < 40 )) && url_w=40

    mapfile -t row_list <<< "$rows"

    printf -v top_border '┌─%s─┬─%s─┬─%s─┐' \
        "$(repeat_char '─' "$port_w")" \
        "$(repeat_char '─' "$label_w")" \
        "$(repeat_char '─' "$url_w")"
    printf -v header_row '│ %s │ %s │ %s │' \
        "$(pad_cell 'Port' "$port_w")" \
        "$(pad_cell 'Profiles' "$label_w")" \
        "$(pad_cell 'Share URLs' "$url_w")"
    printf -v mid_border '├─%s─┼─%s─┼─%s─┤' \
        "$(repeat_char '─' "$port_w")" \
        "$(repeat_char '─' "$label_w")" \
        "$(repeat_char '─' "$url_w")"
    printf '%b%s%b\n' "${CYAN}" "$top_border" "${RESET}"
    printf '%b%s%b\n' "${BOLD}${CYAN}" "$header_row" "${RESET}"
    printf '%b%s%b\n' "${CYAN}" "$mid_border" "${RESET}"

    for idx in "${!row_list[@]}"; do
        row="${row_list[$idx]}"
        [[ -n "${row:-}" ]] || continue
        IFS=$'\t' read -r port label url <<< "$row"

        mapfile -t port_lines < <(wrap_text_lines "$port" "$port_w")
        mapfile -t label_lines < <(wrap_text_lines "$label" "$label_w")
        mapfile -t url_lines < <(wrap_share_url_lines "$url" "$url_w")
        max_lines=${#port_lines[@]}
        (( ${#label_lines[@]} > max_lines )) && max_lines=${#label_lines[@]}
        (( ${#url_lines[@]} > max_lines )) && max_lines=${#url_lines[@]}

        for ((line_idx = 0; line_idx < max_lines; line_idx++)); do
            printf '│ %s │ %s │ %s │\n' \
                "$(pad_cell "${port_lines[$line_idx]:-}" "$port_w")" \
                "$(pad_cell "${label_lines[$line_idx]:-}" "$label_w")" \
                "$(pad_cell "${url_lines[$line_idx]:-}" "$url_w")"
        done

        if (( idx < ${#row_list[@]} - 1 )); then
            printf '%b%s%b\n' "${CYAN}" "$mid_border" "${RESET}"
        fi
    done

    printf -v bottom_border '└─%s─┴─%s─┴─%s─┘' \
        "$(repeat_char '─' "$port_w")" \
        "$(repeat_char '─' "$label_w")" \
        "$(repeat_char '─' "$url_w")"
    printf '%b%s%b\n' "${CYAN}" "$bottom_border" "${RESET}"
}

select_listener_ports_multi() {
    local rows selection

    ensure_fzf_ready || return 1
    rows="$(listener_select_rows)"
    [[ -n "$rows" ]] || {
        warn "No managed listeners found in $SHOES_LISTENER_DIR"
        return 1
    }

    selection="$(printf '%s\n' "$rows" | fzf \
        --multi \
        --delimiter=$'\t' \
        --with-nth=1,2,3 \
        --bind='tab:toggle+down,btab:toggle+up' \
        --prompt='Delete listeners > ' \
        --header=$'TAB mark/unmark | ENTER delete selected ports | ESC cancel' \
        --preview-window='down,60%,wrap' \
        --preview='printf "Port: %s\nProfiles: %s\n\nShare URLs:\n%s\n" {1} {2} {3} | sed "s# || #\n#g"' \
    )" || return 1

    [[ -n "$selection" ]] || return 1
    printf '%s\n' "$selection" | awk -F'\t' '{print $1}' | sort -u
}

list_listeners() {
    local rows

    header "Configured listeners"
    rows="$(listener_detail_rows)"

    if [[ -z "$rows" ]]; then
        warn "No managed listeners found in $SHOES_LISTENER_DIR"
    else
        print_listener_table "$rows"
        info "The table stays as an overview. Full share output is shown below in a cleaner share block format."
        print_share_details "$rows"
    fi

    if base_config_has_content; then
        warn "Additional unmanaged entries exist in $SHOES_BASE_CONFIG and are not listed here."
    fi
}

menu_share_links() {
    local rows selected

    ensure_shoes_ready || return 1
    rows="$(share_catalog_rows)"
    [[ -n "$rows" ]] || {
        warn "No managed share links found."
        return 1
    }

    selected="$(select_share_rows_multi "$rows")" || return 1
    print_share_details "$selected" "true"
}

write_service() {
    init_config
    cat >"$SHOES_SERVICE" <<EOF
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
    systemctl enable shoes >/dev/null 2>&1 || true
    info "shoes.service written."
}

service_action() {
    local action="$1"
    command -v systemctl >/dev/null 2>&1 || { warn "systemctl is unavailable."; return 1; }
    systemctl "$action" shoes && info "shoes $action OK." || warn "systemctl $action shoes returned an error."
}

show_status() {
    command -v systemctl >/dev/null 2>&1 || { warn "systemctl is unavailable."; return 1; }
    systemctl status shoes --no-pager || true
}

show_logs() {
    command -v journalctl >/dev/null 2>&1 || { warn "journalctl is unavailable."; return 1; }
    journalctl -u shoes -n 100 --no-pager || true
}

install_shoes() {
    header "Install / Upgrade shoes ${SHOES_VERSION}"
    local arch tarball url tmpdir binary

    arch="$(detect_arch)"
    tarball="shoes-${arch}.tar.gz"
    url="${GITHUB_RELEASE_BASE}/${tarball}"
    tmpdir="$(mktemp -d)"

    info "Downloading $tarball ..."
    curl -fsSL "$url" -o "${tmpdir}/${tarball}"
    tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"

    binary="$(find "$tmpdir" -maxdepth 2 -type f -name shoes | head -1)"
    [[ -n "$binary" ]] || { rm -rf "$tmpdir"; error "Could not find shoes binary in archive."; exit 1; }

    install -m 755 "$binary" "$SHOES_BIN"
    rm -rf "$tmpdir"

    init_config
    write_service
    info "shoes installed to $SHOES_BIN"
    "$SHOES_BIN" --version 2>/dev/null || true
}

ensure_shoes_ready() {
    if shoes_installed; then
        init_config
        return 0
    fi

    warn "shoes is not installed."
    read -rp "  Install shoes now? [Y/n]: " reply
    if [[ -z "${reply:-}" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]; then
        install_shoes
        return 0
    fi

    return 1
}

shadowtls_installed() {
    [[ -x "$SHADOWTLS_BIN" ]]
}

latest_shadowtls_version() {
    curl -fsSL "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1
}

install_shadowtls() {
    header "Install shadow-tls"
    local arch version download_url tmp_file

    arch="$(detect_arch)"
    version="$(latest_shadowtls_version)"
    [[ -n "$version" ]] || { error "Failed to detect the latest shadow-tls release."; return 1; }

    download_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${arch}"
    tmp_file="$(mktemp)"

    info "Downloading shadow-tls ${version} ..."
    curl -fsSL "$download_url" -o "$tmp_file"
    install -m 755 "$tmp_file" "$SHADOWTLS_BIN"
    rm -f "$tmp_file"

    info "shadow-tls installed to $SHADOWTLS_BIN"
}

ensure_shadowtls_ready() {
    if shadowtls_installed; then
        return 0
    fi

    warn "shadow-tls is not installed."
    read -rp "  Install shadow-tls now? [Y/n]: " reply
    if [[ -z "${reply:-}" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]; then
        install_shadowtls
        return 0
    fi

    return 1
}

uninstall_shoes() {
    header "Uninstall shoes"
    warn "This will stop and remove shoes, its service, and all configuration."
    read -rp "  Are you sure? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; return; }

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop shoes 2>/dev/null || true
        systemctl disable shoes 2>/dev/null || true
    fi

    [[ -f "$SHOES_SERVICE" ]] && rm -f "$SHOES_SERVICE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    [[ -f "$SHOES_BIN" ]] && rm -f "$SHOES_BIN"
    [[ -d "$SHOES_CONFIG_DIR" ]] && rm -rf "$SHOES_CONFIG_DIR"

    info "Uninstall complete."
    exit 0
}

prompt_port() {
    local port
    while true; do
        read -rp "  Port [1-65535]: " port
        [[ "$port" =~ ^[0-9]+$ ]] || { warn "Invalid port number."; continue; }
        (( port >= 1 && port <= 65535 )) || { warn "Invalid port number."; continue; }
        port_in_use "$port" && { warn "Port $port already has a managed listener."; continue; }
        printf '%s\n' "$port"
        return 0
    done
}

prompt_password() {
    local pass
    while true; do
        read -rp "  Password: " pass
        [[ -n "$pass" ]] && { printf '%s\n' "$pass"; return 0; }
        warn "Password cannot be empty."
    done
}

prompt_shadowtls_backend_mode() {
    local choice
    echo "  ShadowTLS mode:" >&2
    echo "    1) Shadowrocket / standalone ShadowTLS (needs a separate SS2022 backend port)" >&2
    echo "    2) shoes native single-port ShadowTLS" >&2

    while true; do
        read -rp "  Choose [2]: " choice
        case "${choice:-2}" in
            1) printf 'standalone\n'; return 0 ;;
            2) printf 'native\n'; return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

prompt_ss2022_cipher() {
    local cipher
    echo "  SS2022 cipher options:" >&2
    echo "    1) 2022-blake3-aes-128-gcm" >&2
    echo "    2) 2022-blake3-aes-256-gcm" >&2
    echo "    3) 2022-blake3-chacha20-ietf-poly1305" >&2

    while true; do
        read -rp "  Cipher [2]: " cipher
        case "${cipher:-2}" in
            1) printf '2022-blake3-aes-128-gcm\n'; return 0 ;;
            2|"") printf '2022-blake3-aes-256-gcm\n'; return 0 ;;
            3) printf '2022-blake3-chacha20-ietf-poly1305\n'; return 0 ;;
            2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-ietf-poly1305) printf '%s\n' "$cipher"; return 0 ;;
            *) warn "Unrecognised cipher." ;;
        esac
    done
}

generate_ss2022_password() {
    local cipher="$1"
    info "Generating password for $cipher ..." >&2
    "$SHOES_BIN" generate-shadowsocks-2022-password "$cipher" | awk '/^Password:/{print $2}'
}

prompt_uuid() {
    local uuid
    while true; do
        read -rp "  UUID: " uuid
        [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] && { printf '%s\n' "$uuid"; return 0; }
        warn "Doesn't look like a valid UUID."
    done
}

prompt_host_for_share() {
    local prompt="$1" default="$2" value
    read -rp "  ${prompt} [${default}]: " value
    printf '%s\n' "${value:-$default}"
}

prompt_tls_insecure_share() {
    local prompt="$1" default="$2" reply

    read -rp "  ${prompt} [${default}]: " reply
    case "${reply:-$default}" in
        y|Y|yes|YES) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

tls_share_extra_query() {
    local insecure="${1:-false}"
    if [[ "$insecure" == "true" ]]; then
        printf '&allowInsecure=1&insecure=1'
    fi
}

hysteria2_share_extra_query() {
    local insecure="${1:-false}"
    if [[ "$insecure" == "true" ]]; then
        printf '&insecure=1'
    fi
}

tuic_share_extra_query() {
    local insecure="${1:-false}"
    if [[ "$insecure" == "true" ]]; then
        printf '&allow_insecure=1&insecure=1'
    fi
}

prompt_existing_tls_inputs() {
    local cert key server_name share_host default_host share_insecure

    read -rp "  TLS cert path: " cert
    read -rp "  TLS key path:  " key
    read -rp "  TLS server name (SNI / domain): " server_name

    [[ -n "$cert" && -n "$key" && -n "$server_name" ]] || {
        warn "Certificate path, key path, and server name are required." >&2
        return 1
    }

    [[ -f "$cert" ]] || { warn "Certificate file not found: $cert" >&2; return 1; }
    [[ -f "$key" ]] || { warn "Key file not found: $key" >&2; return 1; }

    default_host="$server_name"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$default_host")"
    share_insecure="$(prompt_tls_insecure_share "Set insecure/allowInsecure in share URL?" "n")"

    printf '%s\n%s\n%s\n%s\n%s\n' "$cert" "$key" "$server_name" "$share_host" "$share_insecure"
}

prompt_managed_tls_inputs() {
    local selection cert key cert_type detected_name server_name share_host share_insecure default_insecure

    selection="$(select_managed_certificate)" || return 1
    cert="${selection%%|*}"
    key="${selection#*|}"
    cert_type="$(cert_type_from_path "$cert")"
    detected_name="$(cert_name_from_path "$cert")"
    [[ -n "$detected_name" ]] || detected_name="$(certificate_common_name "$cert")"
    detected_name="${detected_name:-$(get_server_ip)}"

    read -rp "  TLS server name (SNI / domain) [${detected_name}]: " server_name
    server_name="${server_name:-$detected_name}"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$server_name")"
    if [[ "$cert_type" == "self-signed" ]]; then
        default_insecure="y"
    else
        default_insecure="n"
    fi
    share_insecure="$(prompt_tls_insecure_share "Set insecure/allowInsecure in share URL?" "$default_insecure")"

    printf '%s\n%s\n%s\n%s\n%s\n' "$cert" "$key" "$server_name" "$share_host" "$share_insecure"
}

prompt_self_signed_tls_inputs() {
    local server_name cert key share_host share_insecure
    local -a cert_paths

    read -rp "  Common Name / SNI for self-signed cert: " server_name
    [[ -n "$server_name" ]] || {
        warn "A Common Name is required." >&2
        return 1
    }

    mapfile -t cert_paths < <(create_self_signed_cert "$server_name") || return 1
    cert="${cert_paths[0]}"
    key="${cert_paths[1]}"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$server_name")"
    share_insecure="$(prompt_tls_insecure_share "Set insecure/allowInsecure in share URL?" "y")"

    info "Self-signed certificate created at $cert" >&2
    printf '%s\n%s\n%s\n%s\n%s\n' "$cert" "$key" "$server_name" "$share_host" "$share_insecure"
}

prompt_acme_tls_inputs() {
    local domain email cert key share_host share_insecure
    local -a cert_paths

    read -rp "  Domain for ACME certificate: " domain
    [[ -n "$domain" ]] || {
        warn "A domain is required." >&2
        return 1
    }

    read -rp "  ACME account email [admin@${domain}]: " email
    email="${email:-admin@${domain}}"

    mapfile -t cert_paths < <(issue_domain_cert "$domain" "$email") || return 1
    cert="${cert_paths[0]}"
    key="${cert_paths[1]}"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$domain")"
    share_insecure="$(prompt_tls_insecure_share "Set insecure/allowInsecure in share URL?" "n")"

    info "Certificate installed at $cert" >&2
    printf '%s\n%s\n%s\n%s\n%s\n' "$cert" "$key" "$domain" "$share_host" "$share_insecure"
}

prompt_tls_inputs() {
    header "TLS certificate source" >&2
    echo "  1) Existing cert and key paths" >&2
    echo "  2) Managed certificate from panel" >&2
    echo "  3) Create a new self-signed certificate" >&2
    echo "  4) Issue a domain certificate with ACME (Let's Encrypt)" >&2

    while true; do
        read -rp "  Choose [1]: " tls_choice
        case "${tls_choice:-1}" in
            1) prompt_existing_tls_inputs; return $? ;;
            2) prompt_managed_tls_inputs; return $? ;;
            3) prompt_self_signed_tls_inputs; return $? ;;
            4) prompt_acme_tls_inputs; return $? ;;
            *) warn "Invalid selection." >&2 ;;
        esac
    done
}

prompt_udp_enabled_yaml() {
    local reply
    read -rp "  Enable UDP support? [Y/n]: " reply
    case "${reply:-y}" in
        y|Y|yes|YES|'') printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

append_anchor() {
    local url="$1" label="$2"
    printf '%s#%s\n' "$url" "$(rawurlencode "$label")"
}

add_http() {
    local port user pass block url url_entries host label

    header "Add HTTP proxy"
    port="$(prompt_port)"
    host="$(get_server_ip)"
    label="HTTP-${port}"

    read -rp "  Username (leave blank for no auth): " user
    if [[ -z "$user" ]]; then
        block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: http"
        url="$(append_anchor "http://${host}:${port}" "$label")"
    else
        pass="$(prompt_password)"
        block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: http
    username: \"${user}\"
    password: \"${pass}\""
        url="$(append_anchor "http://$(rawurlencode "$user"):$(rawurlencode "$pass")@${host}:${port}" "$label")"
    fi

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "HTTP" "$block" "$url_entries" || return 1
    info "HTTP proxy added on port $port."
    print_url "$label" "$url"
}

add_socks5() {
    local port user pass block url url_entries host label udp_enabled

    header "Add SOCKS5 proxy"
    port="$(prompt_port)"
    host="$(get_server_ip)"
    label="SOCKS5-${port}"
    udp_enabled="$(prompt_udp_enabled_yaml)"

    read -rp "  Username (leave blank for no auth): " user
    if [[ -z "$user" ]]; then
        block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: socks
    udp_enabled: ${udp_enabled}"
        url="$(append_anchor "socks5://${host}:${port}" "$label")"
    else
        pass="$(prompt_password)"
        block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: socks
    username: \"${user}\"
    password: \"${pass}\"
    udp_enabled: ${udp_enabled}"
        url="$(append_anchor "socks5://$(rawurlencode "$user"):$(rawurlencode "$pass")@${host}:${port}" "$label")"
    fi

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "SOCKS5" "$block" "$url_entries" || return 1
    info "SOCKS5 proxy added on port $port."
    print_url "$label" "$url"
}

add_shadowsocks() {
    local port cipher pass block host url url_entries userinfo label udp_enabled

    header "Add Shadowsocks proxy"
    port="$(prompt_port)"
    host="$(get_server_ip)"
    label="Shadowsocks-${port}"
    udp_enabled="$(prompt_udp_enabled_yaml)"

    echo "  Cipher options: aes-128-gcm, aes-256-gcm, chacha20-ietf-poly1305"
    read -rp "  Cipher [chacha20-ietf-poly1305]: " cipher
    cipher="${cipher:-chacha20-ietf-poly1305}"
    pass="$(prompt_password)"

    block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: shadowsocks
    cipher: ${cipher}
    password: \"${pass}\"
    udp_enabled: ${udp_enabled}"

    userinfo="$(ss_userinfo_uri "$cipher" "$pass")"
    url="$(append_anchor "ss://${userinfo}@${host}:${port}" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "Shadowsocks" "$block" "$url_entries" || return 1
    info "Shadowsocks added on port $port."
    print_url "$label" "$url"
}

add_shadowsocks2022() {
    local port cipher pass block host url url_entries userinfo label udp_enabled

    header "Add Shadowsocks 2022 proxy"
    port="$(prompt_port)"
    host="$(get_server_ip)"
    label="SS2022-${port}"
    udp_enabled="$(prompt_udp_enabled_yaml)"

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
        *) warn "Unrecognised cipher."; return 1 ;;
    esac

    info "Generating password for $cipher ..."
    pass="$("$SHOES_BIN" generate-shadowsocks-2022-password "$cipher" | awk '/^Password:/{print $2}')"
    [[ -n "$pass" ]] || { warn "Failed to generate SS2022 password."; return 1; }

    block="- address: \"0.0.0.0:${port}\"
  protocol:
    type: shadowsocks
    cipher: ${cipher}
    password: \"${pass}\"
    udp_enabled: ${udp_enabled}"

    userinfo="$(ss_userinfo_uri "$cipher" "$pass")"
    url="$(append_anchor "ss://${userinfo}@${host}:${port}" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "SS2022(${cipher})" "$block" "$url_entries" || return 1
    info "Shadowsocks 2022 added on port $port."
    print_url "$label" "$url"
}

add_trojan() {
    local port pass cert key server_name share_host share_insecure share_query block url url_entries label

    header "Add Trojan proxy"
    port="$(prompt_port)"
    pass="$(prompt_password)"
    mapfile -t tls_values < <(prompt_tls_inputs) || return 1
    [[ ${#tls_values[@]} -ge 5 ]] || return 1
    cert="${tls_values[0]}"
    key="${tls_values[1]}"
    server_name="${tls_values[2]}"
    share_host="${tls_values[3]}"
    share_insecure="${tls_values[4]}"
    share_query="$(tls_share_extra_query "$share_insecure")"
    label="Trojan-${port}"

    block="- address: \"0.0.0.0:${port}\"
  transport: tcp
  protocol:
    type: tls
    sni_targets:
      \"${server_name}\":
        cert: \"${cert}\"
        key: \"${key}\"
        protocol:
          type: trojan
          password: \"${pass}\""

    url="$(append_anchor "trojan://$(rawurlencode "$pass")@${share_host}:${port}?security=tls&sni=$(rawurlencode "$server_name")&type=tcp${share_query}" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "Trojan" "$block" "$url_entries" || return 1
    info "Trojan added on port $port."
    print_url "$label" "$url"
}

add_vmess() {
    local port uuid cipher block url url_entries host label udp_enabled udp_enabled_vmess json

    header "Add VMess proxy"
    port="$(prompt_port)"
    host="$(get_server_ip)"
    uuid="$(prompt_uuid)"
    label="VMess-${port}"
    udp_enabled="$(prompt_udp_enabled_yaml)"

    echo "  Cipher options: aes-128-gcm, chacha20-poly1305, none"
    read -rp "  Cipher [aes-128-gcm]: " cipher
    cipher="${cipher:-aes-128-gcm}"

    block="- address: \"0.0.0.0:${port}\"
  transport: tcp
  protocol:
    type: vmess
    cipher: ${cipher}
    user_id: ${uuid}
    udp_enabled: ${udp_enabled}"

    [[ "$udp_enabled" == "true" ]] && udp_enabled_vmess="1" || udp_enabled_vmess="0"
    json="$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","net":"tcp","type":"none","host":"","path":"","tls":"","scy":"%s","udp":"%s"}' "$label" "$host" "$port" "$uuid" "$cipher" "$udp_enabled_vmess")"
    url="vmess://$(b64enc "$json")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "VMess" "$block" "$url_entries" || return 1
    info "VMess added on port $port."
    print_url "$label" "$url"
}

add_vless() {
    local port uuid cert key server_name share_host share_insecure share_query block url url_entries label udp_enabled

    header "Add VLESS proxy"
    port="$(prompt_port)"
    uuid="$(prompt_uuid)"
    udp_enabled="$(prompt_udp_enabled_yaml)"
    mapfile -t tls_values < <(prompt_tls_inputs) || return 1
    [[ ${#tls_values[@]} -ge 5 ]] || return 1
    cert="${tls_values[0]}"
    key="${tls_values[1]}"
    server_name="${tls_values[2]}"
    share_host="${tls_values[3]}"
    share_insecure="${tls_values[4]}"
    share_query="$(tls_share_extra_query "$share_insecure")"
    label="VLESS-${port}"

    block="- address: \"0.0.0.0:${port}\"
  transport: tcp
  protocol:
    type: tls
    sni_targets:
      \"${server_name}\":
        cert: \"${cert}\"
        key: \"${key}\"
        protocol:
          type: vless
          user_id: ${uuid}
          udp_enabled: ${udp_enabled}"

    url="$(append_anchor "vless://${uuid}@${share_host}:${port}?encryption=none&security=tls&sni=$(rawurlencode "$server_name")&type=tcp${share_query}" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "VLESS" "$block" "$url_entries" || return 1
    info "VLESS added on port $port."
    print_url "$label" "$url"
}

add_vless_reality() {
    local port uuid sni keypair_output private_key public_key short_id host share_host block url url_entries label udp_enabled

    header "Add VLESS-Reality proxy"
    port="$(prompt_port)"
    uuid="$(prompt_uuid)"
    udp_enabled="$(prompt_udp_enabled_yaml)"
    read -rp "  SNI hostname (e.g. www.apple.com): " sni
    sni="${sni:-www.apple.com}"
    host="$(get_server_ip)"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$host")"
    label="VLESS-Reality-${port}"

    info "Generating Reality keypair ..."
    keypair_output="$("$SHOES_BIN" generate-reality-keypair)"
    private_key="$(echo "$keypair_output" | awk '/private key:/{print $NF}')"
    public_key="$(echo "$keypair_output" | awk '/public key:/{print $NF}')"
    short_id="$(openssl rand -hex 8 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 16)"

    [[ -n "$private_key" && -n "$public_key" ]] || { warn "Failed to generate Reality keypair."; return 1; }

    info "Public Key: $public_key"
    info "Short ID : $short_id"

    block="- address: \"0.0.0.0:${port}\"
  transport: tcp
  protocol:
    type: tls
    reality_targets:
      \"${sni}\":
        private_key: \"${private_key}\"
        short_ids: [\"${short_id}\", \"\"]
        dest: \"${sni}:443\"
        vision: true
        protocol:
          type: vless
          user_id: ${uuid}
          udp_enabled: ${udp_enabled}"

    url="$(append_anchor "vless://${uuid}@${share_host}:${port}?encryption=none&security=reality&pbk=$(rawurlencode "$public_key")&sid=$(rawurlencode "$short_id")&sni=$(rawurlencode "$sni")&flow=xtls-rprx-vision&type=tcp&headerType=none&fp=chrome" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "VLESS-Reality" "$block" "$url_entries" || return 1
    info "VLESS-Reality added on port $port."
    print_url "$label" "$url"
}

add_hysteria2() {
    local port pass cert key server_name share_host share_insecure share_query block url url_entries label udp_enabled

    header "Add Hysteria2 proxy"
    port="$(prompt_port)"
    pass="$(prompt_password)"
    udp_enabled="$(prompt_udp_enabled_yaml)"
    mapfile -t tls_values < <(prompt_tls_inputs) || return 1
    [[ ${#tls_values[@]} -ge 5 ]] || return 1
    cert="${tls_values[0]}"
    key="${tls_values[1]}"
    server_name="${tls_values[2]}"
    share_host="${tls_values[3]}"
    share_insecure="${tls_values[4]}"
    share_query="$(hysteria2_share_extra_query "$share_insecure")"
    label="Hysteria2-${port}"

    block="- address: \"0.0.0.0:${port}\"
  transport: quic
  quic_settings:
    cert: \"${cert}\"
    key: \"${key}\"
    alpn_protocols:
      - h3
  protocol:
    type: hysteria2
    password: \"${pass}\"
    udp_enabled: ${udp_enabled}"

    url="$(append_anchor "hysteria2://$(rawurlencode "$pass")@${share_host}:${port}/?sni=$(rawurlencode "$server_name")&alpn=$(rawurlencode "h3")${share_query}" "$label")"
    url_entries="$(url_entry "$label" "$url")"
    url_entries="$(append_url_entry "$url_entries" "HY2-${port}" "$(append_anchor "hy2://$(rawurlencode "$pass")@${share_host}:${port}/?sni=$(rawurlencode "$server_name")&alpn=$(rawurlencode "h3")${share_query}" "HY2-${port}")")"

    add_listener "$port" "Hysteria2" "$block" "$url_entries" || return 1
    info "Hysteria2 added on port $port."
    print_url_entries "$port" "$url_entries" "true"
}

add_tuic() {
    local port uuid pass cert key server_name share_host share_insecure share_query block url url_entries label udp_enabled

    header "Add TUIC v5 proxy"
    port="$(prompt_port)"
    uuid="$(prompt_uuid)"
    pass="$(prompt_password)"
    udp_enabled="$(prompt_udp_enabled_yaml)"
    mapfile -t tls_values < <(prompt_tls_inputs) || return 1
    [[ ${#tls_values[@]} -ge 5 ]] || return 1
    cert="${tls_values[0]}"
    key="${tls_values[1]}"
    server_name="${tls_values[2]}"
    share_host="${tls_values[3]}"
    share_insecure="${tls_values[4]}"
    share_query="$(tuic_share_extra_query "$share_insecure")"
    label="TUIC-${port}"

    block="- address: \"0.0.0.0:${port}\"
  transport: quic
  quic_settings:
    cert: \"${cert}\"
    key: \"${key}\"
    alpn_protocols:
      - h3
  protocol:
    type: tuic
    uuid: ${uuid}
    password: \"${pass}\"
    udp_enabled: ${udp_enabled}"

    url="$(append_anchor "tuic://${uuid}:$(rawurlencode "$pass")@${share_host}:${port}?sni=$(rawurlencode "$server_name")&alpn=$(rawurlencode "h3")&udp_relay_mode=native&congestion_control=cubic${share_query}" "$label")"

    url_entries="$(url_entry "$label" "$url")"
    add_listener "$port" "TUIC v5" "$block" "$url_entries" || return 1
    info "TUIC v5 added on port $port."
    print_url "$label" "$url"
}

write_shadowtls_service_file() {
    local listen_port="$1" backend_port="$2" sni="$3" password="$4"
    local service_file service_name
    service_name="$(shadowtls_service_name_for_port "$listen_port")"
    service_file="$(shadowtls_service_file_for_port "$listen_port")"

    cat >"$service_file" <<EOF
[Unit]
Description=shadow-tls standalone wrapper for backend port ${backend_port}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SHADOWTLS_BIN} --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${backend_port} --tls ${sni} --password ${password}
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${service_name}

[Install]
WantedBy=multi-user.target
EOF
}

start_shadowtls_service() {
    local listen_port="$1"
    local service_name
    command -v systemctl >/dev/null 2>&1 || { warn "systemctl is unavailable."; return 1; }
    service_name="$(shadowtls_service_name_for_port "$listen_port")"
    systemctl daemon-reload
    systemctl enable --now "${service_name}" >/dev/null
}

stop_shadowtls_service() {
    local listen_port="$1"
    local service_name service_file
    command -v systemctl >/dev/null 2>&1 || return 0
    service_name="$(shadowtls_service_name_for_port "$listen_port")"
    service_file="$(shadowtls_service_file_for_port "$listen_port")"
    systemctl stop "${service_name}" 2>/dev/null || true
    systemctl disable "${service_name}" 2>/dev/null || true
    rm -f "$service_file"
    systemctl daemon-reload
}

add_shadowtls_hidden_backend() {
    local backend_port="$1" cipher="$2" password="$3"
    local block hidden_entries

    block="- address: \"0.0.0.0:${backend_port}\"
  protocol:
    type: shadowsocks
    cipher: ${cipher}
    password: \"${password}\"
    udp_enabled: true"

    hidden_entries="$(url_entry "${SHADOWTLS_INTERNAL_LABEL}-${backend_port}" "backend:${backend_port}")"
    add_listener "$backend_port" "ShadowTLS backend ${backend_port}" "$block" "$hidden_entries"
}

add_shadowtls_native() {
    local port pass sni host share_host block url url_entries label inner_choice inner_cipher inner_pass

    port="$(prompt_port)"
    pass="$(prompt_password)"
    read -rp "  Handshake SNI (e.g. www.apple.com): " sni
    sni="${sni:-www.apple.com}"
    host="$(get_server_ip)"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$host")"
    label="ShadowTLS-${port}"

    echo "  Inner protocol:"
    echo "    1) Shadowsocks (chacha20-ietf-poly1305)"
    echo "    2) Shadowsocks 2022 (blake3 ciphers)"
    read -rp "  Choice [1]: " inner_choice

    case "${inner_choice:-1}" in
        2)
            inner_cipher="$(prompt_ss2022_cipher)" || return 1
            inner_pass="$(generate_ss2022_password "$inner_cipher")"
            ;;
        *)
            inner_cipher="chacha20-ietf-poly1305"
            inner_pass="$(openssl rand -base64 16)"
            ;;
    esac

    block="- address: \"0.0.0.0:${port}\"
  transport: tcp
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
          password: \"${inner_pass}\""

    url="$(append_anchor "shadowtls://v3@${share_host}:${port}?password=$(rawurlencode "$pass")&sni=$(rawurlencode "$sni")&inner-ss-pass=$(rawurlencode "$inner_pass")&inner-cipher=$(rawurlencode "$inner_cipher")" "$label")"
    url_entries="$(url_entry "$label" "$url")"

    add_listener "$port" "ShadowTLS-v3" "$block" "$url_entries" || return 1
    info "Native ShadowTLS added on port $port."
    print_url_entries "$port" "$url_entries" "true"
}

add_shadowtls_standalone() {
    local listen_port backend_port pass sni host share_host label cipher ss_password userinfo shadowrocket_param url url_entries

    ensure_shadowtls_ready || return 1

    echo "  Standalone mode will create:"
    echo "    - a hidden SS2022 backend listener inside shoes"
    echo "    - a standalone shadow-tls systemd service for Shadowrocket-style links"

    listen_port="$(prompt_port)"
    while true; do
        backend_port="$(prompt_port)"
        [[ "$backend_port" != "$listen_port" ]] && break
        warn "The backend SS2022 port must differ from the ShadowTLS listen port."
    done

    pass="$(prompt_password)"
    read -rp "  Handshake SNI (e.g. www.apple.com): " sni
    sni="${sni:-www.apple.com}"
    host="$(get_server_ip)"
    share_host="$(prompt_host_for_share "Host shown in share URL" "$host")"
    cipher="$(prompt_ss2022_cipher)" || return 1
    ss_password="$(generate_ss2022_password "$cipher")"
    [[ -n "$ss_password" ]] || { warn "Failed to generate SS2022 password."; return 1; }

    add_shadowtls_hidden_backend "$backend_port" "$cipher" "$ss_password" || return 1

    write_shadowtls_service_file "$listen_port" "$backend_port" "$sni" "$pass"
    if ! start_shadowtls_service "$listen_port"; then
        stop_shadowtls_service "$listen_port"
        remove_listener "$backend_port" true || true
        warn "Failed to start the standalone shadow-tls service."
        return 1
    fi

    write_shadowtls_meta "$listen_port" "$backend_port" "$share_host" "$sni" "$pass" "$cipher" "$ss_password"

    label="ShadowTLS-SS-${listen_port}"
    userinfo="$(ss_userinfo_uri "$cipher" "$ss_password")"
    shadowrocket_param="$(shadowtls_shadowrocket_param "$share_host" "$listen_port" "$sni" "$pass")"
    url="$(append_anchor "ss://${userinfo}@${share_host}:${backend_port}?shadow-tls=${shadowrocket_param}" "$label")"
    url_entries="$(url_entry "$label" "$url")"
    save_url_entries "$listen_port" "$url_entries"

    info "Standalone ShadowTLS added: listen ${listen_port} -> SS2022 backend ${backend_port}."
    print_url_entries "$listen_port" "$url_entries" "true"
}

add_shadowtls() {
    local mode

    header "Add ShadowTLS v3 proxy"
    mode="$(prompt_shadowtls_backend_mode)"
    case "$mode" in
        standalone) add_shadowtls_standalone ;;
        *) add_shadowtls_native ;;
    esac
}

menu_add_protocol() {
    ensure_shoes_ready || return 1
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
            "HTTP") add_http; break ;;
            "SOCKS5") add_socks5; break ;;
            "Shadowsocks") add_shadowsocks; break ;;
            "Shadowsocks 2022") add_shadowsocks2022; break ;;
            "Trojan (TLS)") add_trojan; break ;;
            "VMess") add_vmess; break ;;
            "VLESS (TLS)") add_vless; break ;;
            "VLESS-Reality") add_vless_reality; break ;;
            "ShadowTLS v3") add_shadowtls; break ;;
            "Hysteria2 (QUIC)") add_hysteria2; break ;;
            "TUIC v5 (QUIC)") add_tuic; break ;;
            "Back") break ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

menu_remove_listener() {
    ensure_shoes_ready || return 1
    list_listeners
    local removed=0 port
    local -a ports=()

    mapfile -t ports < <(select_listener_ports_multi) || return 1
    (( ${#ports[@]} > 0 )) || return 0

    printf '  Selected ports: %s\n' "$(join_by ', ' "${ports[@]}")"
    prompt_default_no "  Delete ${#ports[@]} selected listener(s)?" || return 0

    for port in "${ports[@]}"; do
        if remove_listener "$port" true; then
            ((removed++))
        fi
    done

    if (( removed > 0 )); then
        restart_if_running
        info "Removed ${removed} listener(s)."
    fi
}

menu_service() {
    ensure_shoes_ready || return 1
    header "Service Management"
    local options=("Start" "Stop" "Restart" "Status" "Logs" "Back")

    select choice in "${options[@]}"; do
        case "$choice" in
            "Start") service_action start; break ;;
            "Stop") service_action stop; break ;;
            "Restart") service_action restart; break ;;
            "Status") show_status; break ;;
            "Logs") show_logs; break ;;
            "Back") break ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

menu_udp_blocks() {
    local options=("Add UDP block" "List UDP blocks" "Remove UDP block" "Re-apply firewall" "Back")
    local port_spec direction selection entries line selected_direction selected_port
    local -a rules=()

    while true; do
        header "UDP firewall controls"
        select choice in "${options[@]}"; do
            case "$choice" in
                "Add UDP block")
                    port_spec="$(prompt_port_spec)"
                    read -rp "  Direction (input/output/both) [both]: " direction
                    direction="${direction:-both}"
                    case "$direction" in
                        input|output|both)
                            add_udp_block "$port_spec" "$direction" || true
                            [[ "$port_spec" == "443" ]] && warn "UDP/443 usually means QUIC. Blocking it often forces TCP/TLS fallback."
                            ;;
                        *)
                            warn "Invalid direction."
                            ;;
                    esac
                    break
                    ;;
                "List UDP blocks")
                    list_udp_blocks
                    break
                    ;;
                "Remove UDP block")
                    mapfile -t rules < <(grep -Ev '^[[:space:]]*$' "$FIREWALL_RULES" 2>/dev/null || true)
                    if [[ ${#rules[@]} -eq 0 ]]; then
                        warn "No managed UDP block rules."
                        break
                    fi
                    list_udp_blocks
                    read -rp "  Remove which rule #: " selection
                    [[ "$selection" =~ ^[0-9]+$ ]] || { warn "Invalid selection."; break; }
                    (( selection >= 1 && selection <= ${#rules[@]} )) || { warn "Invalid selection."; break; }
                    line="${rules[$((selection - 1))]}"
                    selected_direction="${line%%|*}"
                    selected_port="${line#*|}"
                    remove_udp_block "$selected_direction" "$selected_port" || true
                    break
                    ;;
                "Re-apply firewall")
                    apply_firewall_rules || true
                    info "Firewall rules rendered to $FIREWALL_NFT_FILE"
                    break
                    ;;
                "Back")
                    return 0
                    ;;
                *)
                    warn "Invalid selection."
                    ;;
            esac
        done
    done
}

menu_certificates() {
    local options=("List managed certificates" "Create self-signed certificate" "Issue domain certificate (ACME)" "Back")
    local name domain email
    local -a cert_paths

    while true; do
        header "Certificate management"
        select choice in "${options[@]}"; do
            case "$choice" in
                "List managed certificates")
                    list_managed_certificates
                    break
                    ;;
                "Create self-signed certificate")
                    read -rp "  Common Name / SNI: " name
                    [[ -n "$name" ]] || { warn "A Common Name is required."; break; }
                    mapfile -t cert_paths < <(create_self_signed_cert "$name") || break
                    info "Certificate: ${cert_paths[0]}"
                    info "Key:         ${cert_paths[1]}"
                    break
                    ;;
                "Issue domain certificate (ACME)")
                    read -rp "  Domain: " domain
                    [[ -n "$domain" ]] || { warn "A domain is required."; break; }
                    read -rp "  ACME account email [admin@${domain}]: " email
                    email="${email:-admin@${domain}}"
                    mapfile -t cert_paths < <(issue_domain_cert "$domain" "$email") || break
                    info "Certificate: ${cert_paths[0]}"
                    info "Key:         ${cert_paths[1]}"
                    break
                    ;;
                "Back")
                    return 0
                    ;;
                *)
                    warn "Invalid selection."
                    ;;
            esac
        done
    done
}

main_menu() {
    while true; do
        header "shoes Proxy Panel [${SHOES_VERSION}]"
        local options=(
            "Install / Upgrade shoes"
            "Add protocol"
            "List protocols"
            "Share links / QR"
            "Remove protocol"
            "Certificates"
            "UDP firewall"
            "Service management"
            "Uninstall"
            "Exit"
        )

        select choice in "${options[@]}"; do
            case "$choice" in
                "Install / Upgrade shoes")
                    install_shoes
                    break
                    ;;
                "Add protocol")
                    menu_add_protocol
                    break
                    ;;
                "List protocols")
                    ensure_shoes_ready && list_listeners
                    break
                    ;;
                "Share links / QR")
                    menu_share_links
                    break
                    ;;
                "Remove protocol")
                    menu_remove_listener
                    break
                    ;;
                "Certificates")
                    menu_certificates
                    break
                    ;;
                "UDP firewall")
                    menu_udp_blocks
                    break
                    ;;
                "Service management")
                    menu_service
                    break
                    ;;
                "Uninstall")
                    uninstall_shoes
                    break
                    ;;
                "Exit")
                    echo "Bye."
                    exit 0
                    ;;
                *)
                    warn "Invalid selection."
                    ;;
            esac
        done
    done
}

require_root
main_menu
