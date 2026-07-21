#!/usr/bin/env bash
# WaterWall Proto51 port-forward tunnel installer
#
#   curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
#
set -euo pipefail

REPO_RAW="${WATERWALL_PROTO51_RAW:-https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master}"
WW_RELEASE="${WATERWALL_RELEASE:-v1.46.3}"
WW_REPO="https://github.com/radkesvat/WaterWall/releases/download/${WW_RELEASE}"
INSTALL_DIR="/opt/waterwall-proto51"
SERVICE_NAME="waterwall-proto51"
CONF_ENV="${INSTALL_DIR}/tunnel.env"
BIN_LINK="/usr/local/bin/ww51"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}Run as root:${NC} curl -fsSL ... | sudo bash"
    exit 1
  fi
}

msg()  { echo -e "${CYN}==>${NC} $*"; }
ok()   { echo -e "${GRN}OK${NC} $*"; }
warn() { echo -e "${YLW}WARN${NC} $*"; }
err()  { echo -e "${RED}ERR${NC} $*" >&2; exit 1; }

detect_arch_asset() {
  local arch oldcpu="$1"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      if [[ "$oldcpu" == "1" ]]; then
        echo "Waterwall-linux-gcc-x64-old-cpu.zip"
      else
        echo "Waterwall-linux-gcc-x64.zip"
      fi
      ;;
    aarch64|arm64)
      if [[ "$oldcpu" == "1" ]]; then
        echo "Waterwall-linux-gcc-arm64-old-cpu.zip"
      else
        echo "Waterwall-linux-gcc-arm64.zip"
      fi
      ;;
    *)
      err "Unsupported arch: $arch"
      ;;
  esac
}

ensure_deps() {
  msg "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl unzip ca-certificates jq iproute2 >/dev/null
}

download_waterwall() {
  local oldcpu="$1"
  local asset zip_path
  asset="$(detect_arch_asset "$oldcpu")"
  zip_path="/tmp/${asset}"

  msg "Downloading WaterWall ${WW_RELEASE} (${asset})..."
  curl -fsSL "${WW_REPO}/${asset}" -o "$zip_path"

  mkdir -p "$INSTALL_DIR"
  rm -rf "${INSTALL_DIR}/Waterwall" "${INSTALL_DIR}/libs" 2>/dev/null || true
  unzip -o "$zip_path" -d "$INSTALL_DIR" >/dev/null
  rm -f "$zip_path"

  # binary may be nested
  if [[ ! -f "${INSTALL_DIR}/Waterwall" ]]; then
    local found
    found="$(find "$INSTALL_DIR" -type f -name Waterwall | head -n1 || true)"
    [[ -n "$found" ]] || err "Waterwall binary not found after unzip"
    mv "$found" "${INSTALL_DIR}/Waterwall"
  fi
  chmod +x "${INSTALL_DIR}/Waterwall"
  ok "Waterwall binary ready"
}

gen_key() {
  # AesGcm expects exactly 32 bytes
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o IFS=.
  read -r -a o <<<"$1"
  for x in "${o[@]}"; do
    ((x >= 0 && x <= 255)) || return 1
  done
  return 0
}

normalize_ports() {
  # input: "443 8080,2096" -> "443 8080 2096"
  local raw="$1"
  echo "$raw" | tr ',;' '  ' | xargs
}

validate_ports() {
  local p
  for p in $1; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ((p >= 1 && p <= 65535)) || return 1
  done
  return 0
}

build_port_listeners() {
  local ports="$1"
  local p first=1
  for p in $ports; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ',\n'
    fi
    cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${p},
                "nodelay": true
            },
            "next": "to_kharej"
        }
EOF
  done
}

write_core_json() {
  local side="$1" mtu="$2"
  local cfg="config_${side}.json"
  [[ "$side" == "kharej" ]] && cfg="config_kharej.json"
  [[ "$side" == "ir" ]] && cfg="config_ir.json"

  cat > "${INSTALL_DIR}/core.json" <<EOF
{
    "log": {
        "path": "log/",
        "internal": {
            "loglevel": "INFO",
            "file": "internal.log",
            "console": true
        },
        "core": {
            "loglevel": "INFO",
            "file": "core.log",
            "console": true
        },
        "network": {
            "loglevel": "INFO",
            "file": "network.log",
            "console": true
        },
        "dns": {
            "loglevel": "SILENT",
            "file": "dns.log",
            "console": false
        }
    },
    "dns": {},
    "misc": {
        "workers": 1,
        "mtu": ${mtu},
        "ram-profile": "server",
        "libs-path": "libs/"
    },
    "configs": [
        "${cfg}"
    ]
}
EOF
}

write_iran_config() {
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5" ports="$6"
  local listeners connector aes_node next_after_tun

  listeners="$(build_port_listeners "$ports")"
  connector="$(cat <<'EOF'
        {
            "name": "to_kharej",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "10.10.0.2",
                "port": "src_context->port"
            }
        }
EOF
)"

  if [[ "$encrypt" == "1" ]]; then
    next_after_tun="aes"
    aes_node="$(cat <<EOF
        {
            "name": "aes",
            "type": "AesGcm",
            "settings": {
                "key": "${key}"
            },
            "next": "ipovsrc"
        },
EOF
)"
  else
    next_after_tun="ipovsrc"
    aes_node=""
  fi

  cat > "${INSTALL_DIR}/config_ir.json" <<EOF
{
    "name": "iran",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "${next_after_tun}"
        },
${aes_node}
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "${iran_ip}"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "${kh_ip}"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": ${proto}
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "10.10.0.2"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "${kh_ip}"
            }
        },
${listeners},
${connector}
    ]
}
EOF
}

write_kharej_config() {
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5"
  local aes_node next_after_tun

  if [[ "$encrypt" == "1" ]]; then
    next_after_tun="aes"
    aes_node="$(cat <<EOF
        {
            "name": "aes",
            "type": "AesGcm",
            "settings": {
                "key": "${key}"
            },
            "next": "ipovsrc"
        },
EOF
)"
  else
    next_after_tun="ipovsrc"
    aes_node=""
  fi

  cat > "${INSTALL_DIR}/config_kharej.json" <<EOF
{
    "name": "kharej",
    "nodes": [
        {
            "name": "my tun",
            "type": "TunDevice",
            "settings": {
                "device-name": "wtun0",
                "device-ip": "10.10.0.1/24"
            },
            "next": "${next_after_tun}"
        },
${aes_node}
        {
            "name": "ipovsrc",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "source-ip",
                "ipv4": "${kh_ip}"
            },
            "next": "ipovdest"
        },
        {
            "name": "ipovdest",
            "type": "IpOverrider",
            "settings": {
                "direction": "up",
                "mode": "dest-ip",
                "ipv4": "${iran_ip}"
            },
            "next": "manip"
        },
        {
            "name": "manip",
            "type": "IpManipulator",
            "settings": {
                "protoswap": ${proto}
            },
            "next": "ipovsrc2"
        },
        {
            "name": "ipovsrc2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "source-ip",
                "ipv4": "10.10.0.2"
            },
            "next": "ipovdest2"
        },
        {
            "name": "ipovdest2",
            "type": "IpOverrider",
            "settings": {
                "direction": "down",
                "mode": "dest-ip",
                "ipv4": "10.10.0.1"
            },
            "next": "rd"
        },
        {
            "name": "rd",
            "type": "RawSocket",
            "settings": {
                "capture-filter-mode": "source-ip",
                "capture-ip": "${iran_ip}"
            }
        }
    ]
}
EOF
}

write_env() {
  cat > "$CONF_ENV" <<EOF
SIDE=$1
IRAN_IP=$2
KHAREJ_IP=$3
PROTO=$4
ENCRYPT=$5
AES_KEY=$6
PORTS="$7"
OLDCPU=$8
EOF
  chmod 600 "$CONF_ENV"
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WaterWall Proto51 Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/Waterwall
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

write_menu_wrapper() {
  cat > "$BIN_LINK" <<'EOF'
#!/usr/bin/env bash
exec bash -c 'curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash'
EOF
  # Prefer local copy if present
  cat > "$BIN_LINK" <<EOF
#!/usr/bin/env bash
if [[ -f "${INSTALL_DIR}/install.sh" ]]; then
  exec bash "${INSTALL_DIR}/install.sh" "\$@"
fi
exec bash -c "curl -fsSL ${REPO_RAW}/install.sh | sudo bash"
EOF
  chmod +x "$BIN_LINK"
}

sysctl_tune() {
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-waterwall-proto51.conf <<EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
}

start_service() {
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  sleep 1
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
}

stop_service() {
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
}

uninstall_all() {
  msg "Uninstalling..."
  stop_service
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload || true
  rm -rf "$INSTALL_DIR"
  rm -f "$BIN_LINK"
  rm -f /etc/sysctl.d/99-waterwall-proto51.conf
  ok "Removed ${SERVICE_NAME}"
}

show_status() {
  echo
  if [[ -f "$CONF_ENV" ]]; then
    echo -e "${CYN}Config:${NC}"
    # shellcheck disable=SC1090
    source "$CONF_ENV"
    echo "  side      : ${SIDE:-?}"
    echo "  iran ip   : ${IRAN_IP:-?}"
    echo "  kharej ip : ${KHAREJ_IP:-?}"
    echo "  proto     : ${PROTO:-?}"
    echo "  encrypt   : ${ENCRYPT:-?}"
    echo "  ports     : ${PORTS:-?}"
  else
    warn "No saved config at $CONF_ENV"
  fi
  echo
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  echo
  ip -br addr show wtun0 2>/dev/null || warn "wtun0 not up"
}

prompt_install() {
  local side iran_ip kh_ip ports proto encrypt key oldcpu mtu default_ports
  default_ports="80 443 2053 2083 2087 2096 8080 8443 8880"

  echo
  echo -e "${CYN}Select side:${NC}"
  echo "  1) Iran   (listen 0.0.0.0 and forward selected ports to kharej)"
  echo "  2) Kharej (packet tunnel endpoint; panel should listen on ports)"
  read -r -p "Choice [1/2]: " side
  case "$side" in
    1) side="ir" ;;
    2) side="kharej" ;;
    *) err "Invalid choice" ;;
  esac

  read -r -p "Iran public IP: " iran_ip
  validate_ip "$iran_ip" || err "Invalid Iran IP"
  read -r -p "Kharej public IP: " kh_ip
  validate_ip "$kh_ip" || err "Invalid Kharej IP"

  proto=51
  read -r -p "IP protocol number [${proto}]: " tmp || true
  [[ -n "${tmp:-}" ]] && proto="$tmp"
  [[ "$proto" =~ ^[0-9]+$ ]] && ((proto >= 0 && proto <= 255)) || err "Invalid protocol"

  if [[ "$side" == "ir" ]]; then
    echo "Ports to forward from Iran 0.0.0.0 (space/comma separated)"
    read -r -p "Ports [${default_ports}]: " ports
    ports="$(normalize_ports "${ports:-$default_ports}")"
    validate_ports "$ports" || err "Invalid ports"
  else
    ports=""
    if [[ -f "$CONF_ENV" ]]; then
      # shellcheck disable=SC1090
      source "$CONF_ENV"
      ports="${PORTS:-}"
    fi
  fi

  encrypt=1
  read -r -p "Enable AesGcm encryption? [Y/n]: " tmp || true
  case "${tmp:-Y}" in
    n|N|no|NO) encrypt=0 ;;
    *) encrypt=1 ;;
  esac

  key=""
  if [[ "$encrypt" == "1" ]]; then
    read -r -p "AES key (32 chars, empty=auto): " key || true
    if [[ -z "${key:-}" ]]; then
      key="$(gen_key)"
      echo -e "${YLW}Generated key (save it for the other side):${NC} $key"
    fi
    [[ ${#key} -eq 32 ]] || err "AES key must be exactly 32 characters (got ${#key})"
  fi

  oldcpu=0
  read -r -p "Use old-cpu WaterWall binary? [y/N]: " tmp || true
  case "${tmp:-N}" in
    y|Y|yes|YES) oldcpu=1 ;;
    *) oldcpu=0 ;;
  esac

  if [[ "$side" == "ir" ]]; then mtu=1320; else mtu=1380; fi

  ensure_deps
  download_waterwall "$oldcpu"
  write_core_json "$side" "$mtu"

  if [[ "$side" == "ir" ]]; then
    write_iran_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports"
  else
    write_kharej_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key"
  fi

  # keep installer locally for ww51 menu
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  else
    curl -fsSL "${REPO_RAW}/install.sh" -o "${INSTALL_DIR}/install.sh" || true
  fi
  chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true

  write_env "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu"
  write_service
  write_menu_wrapper
  sysctl_tune

  # disable ufw if present (common for raw/tun tunnels)
  if command -v ufw >/dev/null 2>&1; then
    ufw disable >/dev/null 2>&1 || true
  fi

  start_service

  echo
  ok "Installed on side=${side}"
  echo "  dir     : $INSTALL_DIR"
  echo "  service : systemctl status ${SERVICE_NAME}"
  echo "  menu    : ww51"
  if [[ "$side" == "ir" ]]; then
    echo "  forward : 0.0.0.0:{${ports// /,}} -> ${kh_ip} via 10.10.0.2"
    echo "  note    : on Kharej, panel/xray must listen on the same ports (0.0.0.0 or 10.10.0.1)"
  else
    echo "  note    : start Kharej first, then Iran"
  fi
  if [[ "$encrypt" == "1" ]]; then
    echo -e "  ${YLW}AES key : ${key}${NC}"
    echo "           use the SAME key on both servers"
  fi
}

change_ports() {
  [[ -f "$CONF_ENV" ]] || err "Not installed"
  # shellcheck disable=SC1090
  source "$CONF_ENV"
  [[ "${SIDE}" == "ir" ]] || err "Port forward is configured on Iran side only"

  local ports
  read -r -p "New ports (space/comma) [${PORTS}]: " ports
  ports="$(normalize_ports "${ports:-$PORTS}")"
  validate_ports "$ports" || err "Invalid ports"

  write_iran_config "$IRAN_IP" "$KHAREJ_IP" "$PROTO" "$ENCRYPT" "$AES_KEY" "$ports"
  write_env "ir" "$IRAN_IP" "$KHAREJ_IP" "$PROTO" "$ENCRYPT" "$AES_KEY" "$ports" "${OLDCPU:-0}"
  systemctl restart "$SERVICE_NAME"
  ok "Ports updated: $ports"
}

menu() {
  clear 2>/dev/null || true
  echo -e "${CYN}WaterWall Proto51 Tunnel${NC}"
  echo "========================="
  echo "1) Install / Reinstall"
  echo "2) Status"
  echo "3) Restart"
  echo "4) Change Iran ports"
  echo "5) Uninstall"
  echo "0) Exit"
  echo
  read -r -p "Select: " c
  case "$c" in
    1) prompt_install ;;
    2) show_status ;;
    3) systemctl restart "$SERVICE_NAME"; show_status ;;
    4) change_ports ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) err "Invalid option" ;;
  esac
}

main() {
  need_root
  case "${1:-}" in
    install) prompt_install ;;
    status) show_status ;;
    restart) systemctl restart "$SERVICE_NAME"; show_status ;;
    uninstall) uninstall_all ;;
    ports) change_ports ;;
    *) menu ;;
  esac
}

main "$@"
