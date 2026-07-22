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

# Interactive prompts must use the controlling TTY so `curl | bash` works
# (stdin is the pipe, not the keyboard).
read_tty() {
  if [[ -r /dev/tty ]]; then
    read "$@" </dev/tty
  else
    # fallback for rare non-TTY environments
    read "$@"
  fi
}

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
  if ! apt-get update -y >/dev/null; then
    err "apt-get update failed"
  fi
  if ! apt-get install -y curl unzip ca-certificates jq iproute2 openssl >/dev/null; then
    err "apt-get install failed (need curl unzip jq iproute2 openssl)"
  fi
  command -v curl >/dev/null || err "curl missing after apt install"
  command -v unzip >/dev/null || err "unzip missing after apt install"
  ok "Dependencies ready"
}

download_waterwall() {
  local oldcpu="$1"
  local asset zip_path
  asset="$(detect_arch_asset "$oldcpu")"
  zip_path="/tmp/${asset}"

  msg "Downloading WaterWall ${WW_RELEASE} (${asset})..."
  if ! curl -fL --connect-timeout 30 --max-time 300 "${WW_REPO}/${asset}" -o "$zip_path"; then
    err "Download failed: ${WW_REPO}/${asset}"
  fi
  [[ -s "$zip_path" ]] || err "Downloaded zip is empty: $zip_path"

  msg "Extracting WaterWall binary..."
  mkdir -p "$INSTALL_DIR" "${INSTALL_DIR}/log" "${INSTALL_DIR}/libs"
  rm -f "${INSTALL_DIR}/Waterwall" 2>/dev/null || true
  # Official 1.46.x zips ship a single Waterwall binary (EncryptionClient/Server
  # are statically linked). libs/ is kept for core.json libs-path compatibility only.
  if ! unzip -o "$zip_path" -d "$INSTALL_DIR" >/dev/null; then
    err "unzip failed (is unzip installed?)"
  fi
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
  # Shared EncryptionClient/Server password: exactly 32 alphanumeric chars.
  # IMPORTANT: with set -o pipefail, tr|head -c often exits 141 (SIGPIPE) when
  # head closes the pipe early. That aborts key="$(gen_key)" under set -e with
  # NO error message — looks like a hang right after the key prompt.
  local key=""
  local n=0
  if command -v openssl >/dev/null 2>&1; then
    key="$(openssl rand -hex 16 2>/dev/null || true)"
  fi
  while [[ ${#key} -lt 32 && $n -lt 8 ]]; do
    key+="$( { tr -dc 'A-Za-z0-9' </dev/urandom || true; } | head -c $((32 - ${#key})) || true )"
    n=$((n + 1))
  done
  key="${key:0:32}"
  [[ ${#key} -eq 32 ]] || { echo "ERR failed to generate 32-char AES key" >&2; return 1; }
  printf '%s' "$key"
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

assert_ports_free() {
  # Iran TcpListeners need exclusive bind on 0.0.0.0:port.
  local ports="$1" p busy="" line
  command -v ss >/dev/null 2>&1 || return 0
  for p in $ports; do
    line="$(ss -lntH "sport = :$p" 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      busy+="  port ${p}: ${line}"$'\n'
    fi
  done
  if [[ -n "$busy" ]]; then
    echo -e "${RED}ERR${NC} These ports are already in use (WaterWall cannot bind):" >&2
    echo -e "$busy" >&2
    echo "Free them (stop x-ui/backhaul/nginx/etc. on Iran) or choose different ports." >&2
    echo "Hint: ss -lntup | grep -E ':PORT'" >&2
    exit 1
  fi
}

# Official docs:
#   https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient
#   https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionServer
# Pattern: TcpListener -> EncryptionClient -> TcpConnector  (Iran)
#          TcpListener -> EncryptionServer -> TcpConnector  (Kharej)
# AesGcm is NOT in WaterWall 1.46.x (no tunnel, no libs plugin) — do not use it.
#
# Docs default algorithm is chacha20-poly1305. old-cpu WaterWall builds often
# lack AES-GCM in the active crypto backend and FATAL on:
#   "AES-GCM selected but it is unavailable in the active crypto backend"
ENC_SALT_DEFAULT="waterwall-proto51"
ENC_ALGO_DEFAULT="chacha20-poly1305"
ENC_KDF_DEFAULT="12000"
# Active algorithm written into configs / tunnel.env (set by probe).
ENC_ALGO="$ENC_ALGO_DEFAULT"

binary_has_string() {
  local bin="$1" needle="$2"
  grep -a -F -q -- "$needle" "$bin" 2>/dev/null
}

cpu_has_aes_ni() {
  # x86: "aes" in flags; aarch64 sometimes exposes AES via Features.
  grep -qiE '(^flags|^Features).*[[:space:]]aes([[:space:]]|$)' /proc/cpuinfo 2>/dev/null
}

probe_encryption_algorithm() {
  # Echo a usable EncryptionClient/Server algorithm for the installed binary.
  # Prefer chacha20-poly1305 (docs default; works without AES-NI / old-cpu).
  # Never select aes-gcm for old-cpu binaries — backend typically cannot provide it.
  # Returns 0 + prints algo, or 1 if nothing usable.
  local oldcpu="${1:-0}"
  local bin="${INSTALL_DIR}/Waterwall"
  local has_chacha=0 has_aes=0

  [[ -x "$bin" ]] || return 1

  if binary_has_string "$bin" "chacha20-poly1305" \
    || binary_has_string "$bin" "chacha20poly1305" \
    || binary_has_string "$bin" "chacha20" \
    || binary_has_string "$bin" "chacha"; then
    has_chacha=1
  fi
  if binary_has_string "$bin" "aes-gcm" \
    || binary_has_string "$bin" "aes-256-gcm" \
    || binary_has_string "$bin" "aes256gcm" \
    || binary_has_string "$bin" "aes256-gcm"; then
    has_aes=1
  fi

  # old-cpu release builds: AES-GCM string may exist but crypto backend rejects it.
  if [[ "$oldcpu" == "1" ]]; then
    has_aes=0
  elif ! cpu_has_aes_ni; then
    # Soft AES without AES-NI is slow and some backends still refuse AES-GCM.
    has_aes=0
  fi

  # Must not print status on stdout — caller captures the algorithm name.
  echo -e "${CYN}==>${NC} Crypto probe: old-cpu=${oldcpu} chacha=${has_chacha} aes-gcm=${has_aes} aes-ni=$(cpu_has_aes_ni && echo 1 || echo 0)" >&2

  if [[ "$has_chacha" -eq 1 ]]; then
    printf '%s' "chacha20-poly1305"
    return 0
  fi
  if [[ "$has_aes" -eq 1 ]]; then
    printf '%s' "aes-gcm"
    return 0
  fi
  return 1
}

ensure_encryption_support() {
  # EncryptionClient/Server are statically linked in official WaterWall builds.
  # Probe AEAD algorithms and set ENC_ALGO. Return 0 if encryption can proceed,
  # 1 if caller should disable encryption (no usable AEAD) instead of crashing.
  # Arg: oldcpu (0|1). AesGcm plugin is never used.
  local oldcpu="${1:-0}"
  local bin="${INSTALL_DIR}/Waterwall"
  local algo=""

  [[ -x "$bin" ]] || err "Waterwall binary missing at $bin (download first)"
  if ! binary_has_string "$bin" "EncryptionClient"; then
    warn "This WaterWall binary lacks EncryptionClient (need v1.46+)."
    return 1
  fi
  if ! binary_has_string "$bin" "EncryptionServer"; then
    warn "This WaterWall binary lacks EncryptionServer (need v1.46+)."
    return 1
  fi
  ok "EncryptionClient/Server present in binary (no libs/ plugin required)"

  if ! algo="$(probe_encryption_algorithm "$oldcpu")"; then
    warn "No usable AEAD algorithm for this binary/CPU (old-cpu often lacks AES-GCM)."
    warn "Docs alternatives: chacha20-poly1305 (preferred), aes-gcm / aes-256-gcm."
    return 1
  fi
  ENC_ALGO="$algo"
  ok "Selected encryption algorithm: ${ENC_ALGO} (salt=${ENC_SALT_DEFAULT})"
  return 0
}

resolve_encryption_or_fallback() {
  # If encrypt=1, probe algorithms. On failure: warn and force encrypt=0.
  # Sets globals: ENC_ALGO, and echoes "encrypt key" via nameref-style globals
  # Caller passes encrypt/key by name through globals ENCRYPT_RESOLVED / KEY_RESOLVED
  # Actually: mutate caller's locals via eval-free pattern — return via globals.
  # Usage: resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
  #         then read ENCRYPT_RESOLVED KEY_RESOLVED
  local want="$1" key="$2" oldcpu="$3"
  ENCRYPT_RESOLVED="$want"
  KEY_RESOLVED="$key"
  ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"

  if [[ "$want" != "1" ]]; then
    ENCRYPT_RESOLVED=0
    KEY_RESOLVED=""
    return 0
  fi

  if ensure_encryption_support "$oldcpu"; then
    ENCRYPT_RESOLVED=1
    KEY_RESOLVED="$key"
    return 0
  fi

  warn "============================================================"
  warn "Encryption requested but no AEAD works on this crypto backend."
  warn "Auto-fallback: installing WITHOUT encryption (service stays up)."
  warn "Both Iran and Kharej must use the same encrypt setting."
  warn "============================================================"
  ENCRYPT_RESOLVED=0
  KEY_RESOLVED=""
  ENC_ALGO="$ENC_ALGO_DEFAULT"
  return 0
}

build_iran_forward_nodes() {
  # WaterWall 1.46+ auto-inserts TcpConnector.domain-resolver and does NOT allow
  # multiple listeners to share one connector next. Emit one chain per port.
  # encrypt=1: TcpListener -> EncryptionClient -> TcpConnector(10.10.0.2:port)
  local ports="$1" encrypt="$2" key="$3"
  local p first=1 next_name
  for p in $ports; do
    if [[ $first -eq 1 ]]; then
      first=0
    else
      printf ',\n'
    fi
    if [[ "$encrypt" == "1" ]]; then
      next_name="enc${p}"
      cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${p},
                "nodelay": true
            },
            "next": "${next_name}"
        },
        {
            "name": "${next_name}",
            "type": "EncryptionClient",
            "settings": {
                "algorithm": "${ENC_ALGO}",
                "password": "${key}",
                "salt": "${ENC_SALT_DEFAULT}",
                "kdf-iterations": ${ENC_KDF_DEFAULT}
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "10.10.0.2",
                "port": ${p}
            }
        }
EOF
    else
      cat <<EOF
        {
            "name": "p${p}",
            "type": "TcpListener",
            "settings": {
                "address": "0.0.0.0",
                "port": ${p},
                "nodelay": true
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "10.10.0.2",
                "port": ${p}
            }
        }
EOF
    fi
  done
}

build_kharej_decrypt_nodes() {
  # When encryption is ON, Kharej decrypts on the TUN IP then hands plain TCP
  # to the panel on 127.0.0.1 (panel must NOT bind 0.0.0.0/10.10.0.1).
  # TcpListener(10.10.0.1) -> EncryptionServer -> TcpConnector(127.0.0.1)
  local ports="$1" key="$2"
  local p first=1
  [[ -n "$ports" ]] || return 0
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
                "address": "10.10.0.1",
                "port": ${p},
                "nodelay": true
            },
            "next": "enc${p}"
        },
        {
            "name": "enc${p}",
            "type": "EncryptionServer",
            "settings": {
                "algorithm": "${ENC_ALGO}",
                "password": "${key}",
                "salt": "${ENC_SALT_DEFAULT}",
                "kdf-iterations": ${ENC_KDF_DEFAULT}
            },
            "next": "c${p}"
        },
        {
            "name": "c${p}",
            "type": "TcpConnector",
            "settings": {
                "nodelay": true,
                "address": "127.0.0.1",
                "port": ${p}
            }
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
        "ram-profile": "client",
        "libs-path": "libs/"
    },
    "configs": [
        "${cfg}"
    ]
}
EOF
}

write_iran_config() {
  # Packet path stays unencrypted (TunDevice...RawSocket + protoswap).
  # Optional AEAD sits on the TCP forward chains (EncryptionClient).
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5" ports="$6"
  local forward_nodes

  forward_nodes="$(build_iran_forward_nodes "$ports" "$encrypt" "$key")"

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
            "next": "ipovsrc"
        },
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
${forward_nodes}
    ]
}
EOF
}

write_kharej_config() {
  # Packet path: TunDevice...RawSocket + protoswap (same PROTO as Iran).
  # encrypt=1: add EncryptionServer listeners on 10.10.0.1 -> 127.0.0.1 panel.
  local iran_ip="$1" kh_ip="$2" proto="$3" encrypt="$4" key="$5" ports="$6"
  local decrypt_nodes="" decrypt_block=""

  if [[ "$encrypt" == "1" ]]; then
    decrypt_nodes="$(build_kharej_decrypt_nodes "$ports" "$key")"
    [[ -n "$decrypt_nodes" ]] || err "Encryption enabled but no ports configured (needed on Kharej for EncryptionServer)"
    decrypt_block=",
${decrypt_nodes}"
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
            "next": "ipovsrc"
        },
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
        }${decrypt_block}
    ]
}
EOF
}

write_env() {
  # PROTO = IpManipulator protoswap (0-255). ENCRYPT=1 uses EncryptionClient/Server.
  # AES_KEY is the shared Encryption password (32 chars). Not the removed AesGcm node.
  # ENC_ALGO is the probed AEAD (usually chacha20-poly1305 on old-cpu).
  cat > "$CONF_ENV" <<EOF
SIDE=$1
IRAN_IP=$2
KHAREJ_IP=$3
PROTO=$4
ENCRYPT=$5
AES_KEY=$6
PORTS="$7"
OLDCPU=$8
ENC_ALGO=${ENC_ALGO:-$ENC_ALGO_DEFAULT}
ENC_SALT=${ENC_SALT_DEFAULT}
EOF
  chmod 600 "$CONF_ENV"
}

write_service() {
  # WaterWall needs root for TunDevice (/dev/net/tun) + RawSocket.
  # Do not sandbox with NoNewPrivileges/CapabilityBoundingSet — those break TUN/raw.
  # StartLimitIntervalSec=0: never give up restarting after reboot or crash loops.
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WaterWall Proto51 Tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/Waterwall
Restart=always
RestartSec=5
LimitNOFILE=1048576
# Root + no privilege sandbox: TunDevice and RawSocket need unrestricted net admin.
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
}

write_watchdog() {
  # Lightweight self-contained recovery: timer every 2m checks service + wtun0.
  mkdir -p "$INSTALL_DIR"
  cat > "${INSTALL_DIR}/watchdog.sh" <<'EOF'
#!/usr/bin/env bash
# waterwall-proto51 watchdog — restart if service inactive or wtun0 missing
set -euo pipefail
SERVICE_NAME="waterwall-proto51"
LOG_TAG="waterwall-proto51-watchdog"

need_restart=0
state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
if [[ "$state" != "active" ]]; then
  need_restart=1
  logger -t "$LOG_TAG" "service not active (state=${state:-unknown}); restarting"
fi

if ! ip link show wtun0 >/dev/null 2>&1; then
  need_restart=1
  logger -t "$LOG_TAG" "wtun0 missing; restarting ${SERVICE_NAME}"
fi

if [[ "$need_restart" -eq 1 ]]; then
  systemctl restart "${SERVICE_NAME}.service" || true
fi
exit 0
EOF
  chmod 755 "${INSTALL_DIR}/watchdog.sh"

  cat > "/etc/systemd/system/${SERVICE_NAME}-watchdog.service" <<EOF
[Unit]
Description=WaterWall Proto51 Watchdog (oneshot check)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/watchdog.sh
Nice=10
EOF

  cat > "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer" <<EOF
[Unit]
Description=WaterWall Proto51 Watchdog Timer (every 2 minutes)
Requires=${SERVICE_NAME}-watchdog.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
Unit=${SERVICE_NAME}-watchdog.service

[Install]
WantedBy=timers.target
EOF
}

enable_watchdog() {
  msg "Enabling ${SERVICE_NAME}-watchdog.timer..."
  write_watchdog
  systemctl daemon-reload || err "systemctl daemon-reload failed (watchdog)"
  systemctl enable --now "${SERVICE_NAME}-watchdog.timer" \
    || err "Failed to enable ${SERVICE_NAME}-watchdog.timer"
  ok "Watchdog timer enabled (checks every ~2 minutes)"
}

disable_watchdog() {
  systemctl disable --now "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || true
  systemctl stop "${SERVICE_NAME}-watchdog.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
  rm -f "/etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
  rm -f "${INSTALL_DIR}/watchdog.sh"
}

write_menu_wrapper() {
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

show_failure_logs() {
  echo
  warn "Service is NOT healthy. Recent journal:"
  journalctl -u "${SERVICE_NAME}" -n 50 --no-pager || true
  echo
  if compgen -G "${INSTALL_DIR}/log/*.log" >/dev/null 2>&1; then
    warn "WaterWall log files:"
    # shellcheck disable=SC2012
    ls -1t "${INSTALL_DIR}"/log/*.log 2>/dev/null | head -n 4 | while read -r f; do
      echo "---- ${f} (tail) ----"
      tail -n 30 "$f" 2>/dev/null || true
    done
  fi
}

start_service() {
  msg "Enabling and starting ${SERVICE_NAME}.service..."
  systemctl daemon-reload || err "systemctl daemon-reload failed"
  systemctl enable "${SERVICE_NAME}.service" || err "Failed to enable ${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || true
  sleep 2

  local state result
  state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  result="$(systemctl show -p Result --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true

  if [[ "$state" == "active" ]]; then
    ok "Service is active (running)"
    return 0
  fi

  show_failure_logs
  err "Service failed to stay running (state=${state:-unknown} result=${result:-unknown}). See logs above."
}

stop_service() {
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
}

uninstall_all() {
  msg "Uninstalling..."
  disable_watchdog
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
    echo "  proto     : ${PROTO:-?}  (IpManipulator protoswap; editable via menu 4)"
    echo "  encrypt   : ${ENCRYPT:-0}  (0=off, 1=EncryptionClient/Server AEAD)"
    echo "  enc algo  : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}"
    echo "  ports     : ${PORTS:-?}"
    echo "  old-cpu   : ${OLDCPU:-0}"
  else
    warn "No saved config at $CONF_ENV"
  fi
  echo
  echo -e "${CYN}Service:${NC}"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  echo
  echo -e "${CYN}Watchdog timer:${NC}"
  systemctl --no-pager --full status "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || warn "watchdog timer not installed"
  systemctl list-timers "${SERVICE_NAME}-watchdog.timer" --no-pager 2>/dev/null || true
  echo
  echo -e "${CYN}Interface:${NC}"
  ip -br addr show wtun0 2>/dev/null || warn "wtun0 not up"
  echo
  echo -e "${CYN}Enabled at boot:${NC}"
  systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl is-enabled "${SERVICE_NAME}-watchdog.timer" 2>/dev/null || true
}

apply_tunnel_config() {
  # Regenerate JSON from args and restart (no full reinstall).
  # args: side iran_ip kh_ip proto encrypt key ports oldcpu
  local side="$1" iran_ip="$2" kh_ip="$3" proto="$4" encrypt="$5" key="$6" ports="$7" oldcpu="$8"
  local mtu

  if [[ "$side" == "ir" ]]; then mtu=1320; else mtu=1380; fi

  if [[ "$encrypt" == "1" ]]; then
    resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
    encrypt="$ENCRYPT_RESOLVED"
    key="$KEY_RESOLVED"
    if [[ "$encrypt" == "1" ]]; then
      [[ -n "$ports" ]] || err "Encryption requires PORTS on both sides (same list)"
      [[ ${#key} -eq 32 ]] || err "Encryption password must be exactly 32 characters"
    fi
  else
    ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"
  fi

  # Stop first so port-free check does not see our own listeners.
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  sleep 1

  write_core_json "$side" "$mtu"
  if [[ "$side" == "ir" ]]; then
    assert_ports_free "$ports"
    write_iran_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports"
  else
    if [[ "$encrypt" == "1" ]]; then
      assert_ports_free "$ports"
    fi
    write_kharej_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports"
  fi
  write_env "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu"
  write_service
  systemctl daemon-reload || true
  systemctl enable "${SERVICE_NAME}.service" || warn "Could not enable ${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service" || true
  sleep 2
  if [[ "$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)" == "active" ]]; then
    ok "Tunnel config applied; service active (PROTO=${proto} ENCRYPT=${encrypt} ALGO=${ENC_ALGO})"
    return 0
  fi
  show_failure_logs
  err "Service failed after config update"
}

edit_tunnel() {
  [[ -f "$CONF_ENV" ]] || err "Not installed (missing $CONF_ENV). Run Install first."
  # shellcheck disable=SC1090
  source "$CONF_ENV"

  local side iran_ip kh_ip ports proto encrypt key oldcpu tmp
  side="${SIDE:-}"
  iran_ip="${IRAN_IP:-}"
  kh_ip="${KHAREJ_IP:-}"
  ports="${PORTS:-}"
  proto="${PROTO:-51}"
  encrypt="${ENCRYPT:-0}"
  key="${AES_KEY:-}"
  oldcpu="${OLDCPU:-0}"
  ENC_ALGO="${ENC_ALGO:-$ENC_ALGO_DEFAULT}"

  [[ -n "$side" && -n "$iran_ip" && -n "$kh_ip" ]] || err "tunnel.env incomplete; reinstall"

  echo
  echo -e "${CYN}Edit tunnel${NC} (Enter keeps current value)"
  echo "  current side : ${side}"
  echo "  PROTO is saved to tunnel.env and written into IpManipulator.protoswap"
  echo

  read_tty -r -p "Iran public IP [${iran_ip}]: " tmp || true
  [[ -n "${tmp:-}" ]] && iran_ip="$tmp"
  validate_ip "$iran_ip" || err "Invalid Iran IP"

  read_tty -r -p "Kharej public IP [${kh_ip}]: " tmp || true
  [[ -n "${tmp:-}" ]] && kh_ip="$tmp"
  validate_ip "$kh_ip" || err "Invalid Kharej IP"

  echo
  echo -e "${CYN}IP protocol number (protoswap)${NC} — must match on Iran and Kharej"
  read_tty -r -p "Protocol [${proto}]: " tmp || true
  [[ -n "${tmp:-}" ]] && proto="$tmp"
  [[ "$proto" =~ ^[0-9]+$ ]] && ((proto >= 0 && proto <= 255)) || err "Invalid protocol (0-255)"

  local enc_prompt="N"
  [[ "$encrypt" == "1" ]] && enc_prompt="Y"
  echo
  echo -e "${CYN}Encryption${NC} (official WaterWall AEAD nodes — NOT the removed AesGcm plugin)"
  echo "  Iran  : TcpListener -> EncryptionClient -> TcpConnector"
  echo "  Kharej: TcpListener(10.10.0.1) -> EncryptionServer -> TcpConnector(127.0.0.1)"
  echo "  Docs  : https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient"
  echo "  Algo  : auto-probe (prefer chacha20-poly1305; current saved: ${ENC_ALGO:-$ENC_ALGO_DEFAULT})"
  echo "  Default OFF for safety. No libs/ plugin required (nodes are built into the binary)."
  read_tty -r -p "Enable EncryptionClient/Server? [y/N] (current: ${enc_prompt}): " tmp || true
  case "${tmp:-}" in
    y|Y|yes|YES) encrypt=1 ;;
    n|N|no|NO) encrypt=0 ;;
    "") ;; # keep current
    *) warn "Keeping current encrypt=${encrypt}" ;;
  esac

  # Ports: always on Iran; also required on Kharej when encryption is on.
  if [[ "$side" == "ir" || "$encrypt" == "1" ]]; then
    local ports_label="Listen / forward ports"
    [[ "$side" == "kharej" ]] && ports_label="Same ports as Iran (Kharej EncryptionServer)"
    read_tty -r -p "${ports_label} [${ports:-80 443}]: " tmp || true
    [[ -n "${tmp:-}" ]] && ports="$(normalize_ports "$tmp")"
    ports="$(normalize_ports "${ports:-}")"
    [[ -n "$ports" ]] || err "Ports required"
    validate_ports "$ports" || err "Invalid ports"
  fi

  if [[ "$encrypt" == "1" ]]; then
    read_tty -r -p "Shared password / AES key (32 chars) [${key:-empty=auto}]: " tmp || true
    if [[ -n "${tmp:-}" ]]; then
      key="$tmp"
    elif [[ -z "${key:-}" ]]; then
      msg "Generating 32-char key..."
      key="$(gen_key)" || err "Key auto-generation failed"
      echo -e "${YLW}Generated key (use SAME on other side):${NC} ${GRN}${key}${NC}"
    fi
    [[ ${#key} -eq 32 ]] || err "Key must be exactly 32 characters (got ${#key})"
  else
    key=""
  fi

  local old_prompt="N"
  [[ "$oldcpu" == "1" ]] && old_prompt="Y"
  local prev_oldcpu="$oldcpu"
  read_tty -r -p "Use old-cpu WaterWall binary? [y/N] (current: ${old_prompt}): " tmp || true
  case "${tmp:-}" in
    y|Y|yes|YES) oldcpu=1 ;;
    n|N|no|NO) oldcpu=0 ;;
    "") ;; # keep
    *) ;;
  esac

  msg "Rewriting configs from edited values..."
  if [[ "$oldcpu" != "$prev_oldcpu" ]] || [[ ! -x "${INSTALL_DIR}/Waterwall" ]]; then
    ensure_deps
    download_waterwall "$oldcpu"
  fi

  # refresh cached installer if possible
  if [[ -f "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  fi

  apply_tunnel_config "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu"
  enable_watchdog

  echo
  ok "Edit applied on side=${side}"
  echo "  iran ip   : $iran_ip"
  echo "  kharej ip : $kh_ip"
  echo "  proto     : $proto   (saved in $CONF_ENV as PROTO=)"
  echo "  encrypt   : $encrypt"
  echo "  ports     : ${ports:-none}"
  if [[ "$encrypt" == "1" ]]; then
    echo -e "  ${YLW}key       : ${key}${NC}"
    echo "  algorithm : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}  salt=${ENC_SALT_DEFAULT}"
    if [[ "$side" == "kharej" ]]; then
      echo -e "  ${YLW}Kharej panel must listen on 127.0.0.1 (same ports). WaterWall binds 10.10.0.1.${NC}"
    fi
  fi
  echo "  Apply the same IPs / PROTO / encrypt / key / ports / algorithm on the other server if you changed them."
}

prompt_install() {
  local side iran_ip kh_ip ports proto encrypt key oldcpu mtu default_ports
  default_ports="80 443 2053 2083 2087 2096 8080 8443 8880"

  echo
  echo -e "${CYN}Select side:${NC}"
  echo "  1) Iran   (listen 0.0.0.0 and forward selected ports to kharej)"
  echo "  2) Kharej (packet tunnel endpoint; panel should listen on ports)"
  read_tty -r -p "Choice [1/2]: " side
  case "$side" in
    1) side="ir" ;;
    2) side="kharej" ;;
    *) err "Invalid choice" ;;
  esac

  read_tty -r -p "Iran public IP: " iran_ip
  validate_ip "$iran_ip" || err "Invalid Iran IP"
  read_tty -r -p "Kharej public IP: " kh_ip
  validate_ip "$kh_ip" || err "Invalid Kharej IP"

  echo
  echo -e "${CYN}IP protocol number (protoswap)${NC}"
  echo "  Saved as PROTO in tunnel.env; must be identical on Iran and Kharej."
  echo "  You can change it later via menu 4) Edit tunnel."
  proto=51
  read_tty -r -p "Protocol number [${proto}]: " tmp || true
  [[ -n "${tmp:-}" ]] && proto="$tmp"
  [[ "$proto" =~ ^[0-9]+$ ]] && ((proto >= 0 && proto <= 255)) || err "Invalid protocol (0-255)"

  # Default OFF until user opts in. Encryption uses built-in EncryptionClient/Server
  # (docs), not the removed AesGcm dynamic library that crashed with:
  #   library "AesGcm" ... could not be loaded
  encrypt=0
  echo
  echo -e "${CYN}Encryption (optional, default OFF)${NC}"
  echo "  Uses official AEAD nodes EncryptionClient + EncryptionServer (built into binary)."
  echo "  Docs: https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient"
  echo "  Algorithm auto-selected after download (prefer chacha20-poly1305; aes-gcm only if usable)."
  echo "  old-cpu binaries: AES-GCM is unavailable — script uses chacha20-poly1305 or falls back to OFF."
  echo "  No libs/ plugin download is required. AesGcm plugin is NOT used."
  read_tty -r -p "Enable EncryptionClient/Server? [y/N]: " tmp || true
  case "${tmp:-N}" in
    y|Y|yes|YES) encrypt=1 ;;
    *) encrypt=0 ;;
  esac

  ports=""
  if [[ "$side" == "ir" ]]; then
    echo "Ports to forward from Iran 0.0.0.0 (space/comma separated)"
    read_tty -r -p "Ports [${default_ports}]: " ports
    ports="$(normalize_ports "${ports:-$default_ports}")"
    validate_ports "$ports" || err "Invalid ports"
  elif [[ "$encrypt" == "1" ]]; then
    echo "Kharej needs the SAME ports (EncryptionServer on 10.10.0.1 -> panel 127.0.0.1)"
    if [[ -f "$CONF_ENV" ]]; then
      # shellcheck disable=SC1090
      source "$CONF_ENV"
      ports="${PORTS:-}"
    fi
    read_tty -r -p "Ports [${ports:-$default_ports}]: " tmp || true
    ports="$(normalize_ports "${tmp:-${ports:-$default_ports}}")"
    validate_ports "$ports" || err "Invalid ports"
  else
    if [[ -f "$CONF_ENV" ]]; then
      # shellcheck disable=SC1090
      source "$CONF_ENV"
      ports="${PORTS:-}"
    fi
  fi

  key=""
  if [[ "$encrypt" == "1" ]]; then
    read_tty -r -p "Shared password / AES key (32 chars, empty=auto): " key || true
    if [[ -z "${key:-}" ]]; then
      msg "Generating 32-char key..."
      key="$(gen_key)" || err "Key auto-generation failed"
      echo
      echo -e "${YLW}Generated key (save + use SAME key on the other side):${NC}"
      echo -e "  ${GRN}${key}${NC}"
      echo
    fi
    [[ ${#key} -eq 32 ]] || err "Key must be exactly 32 characters (got ${#key})"
  fi

  oldcpu=0
  read_tty -r -p "Use old-cpu WaterWall binary? [y/N]: " tmp || true
  case "${tmp:-N}" in
    y|Y|yes|YES) oldcpu=1 ;;
    *) oldcpu=0 ;;
  esac

  if [[ "$side" == "ir" ]]; then mtu=1320; else mtu=1380; fi

  msg "Starting install for side=${side}..."
  ensure_deps
  download_waterwall "$oldcpu"

  if [[ "$encrypt" == "1" ]]; then
    resolve_encryption_or_fallback "$encrypt" "$key" "$oldcpu"
    encrypt="$ENCRYPT_RESOLVED"
    key="$KEY_RESOLVED"
  else
    ENC_ALGO="$ENC_ALGO_DEFAULT"
  fi

  msg "Writing core.json and tunnel config..."
  write_core_json "$side" "$mtu"

  if [[ "$side" == "ir" ]]; then
    msg "Checking Iran listen ports are free..."
    assert_ports_free "$ports"
    write_iran_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports"
  else
    if [[ "$encrypt" == "1" ]]; then
      msg "Checking Kharej decrypt listen ports are free..."
      assert_ports_free "$ports"
    fi
    write_kharej_config "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports"
  fi
  ok "Config files written under $INSTALL_DIR"

  # keep installer locally for ww51 menu
  msg "Saving installer copy..."
  if [[ -f "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  fi
  if [[ ! -f "${INSTALL_DIR}/install.sh" ]]; then
    curl -fsSL "${REPO_RAW}/install.sh" -o "${INSTALL_DIR}/install.sh" || warn "Could not cache install.sh locally"
  fi
  chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true

  msg "Writing config (tunnel.env)..."
  write_env "$side" "$iran_ip" "$kh_ip" "$proto" "$encrypt" "$key" "$ports" "$oldcpu"
  [[ -f "$CONF_ENV" ]] || err "Failed to write $CONF_ENV"

  msg "Installing systemd unit..."
  write_service
  [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || err "Failed to write systemd unit"
  write_menu_wrapper
  sysctl_tune

  # disable ufw if present (common for raw/tun tunnels)
  if command -v ufw >/dev/null 2>&1; then
    msg "Disabling ufw (raw/tun tunnels)..."
    ufw disable >/dev/null 2>&1 || true
  fi

  start_service
  enable_watchdog

  # Verify boot persistence
  if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    ok "Service enabled at boot (survives reboot)"
  else
    warn "Service may not be enabled at boot — run: systemctl enable ${SERVICE_NAME}"
  fi

  echo
  ok "Installed on side=${side}"
  echo "  dir      : $INSTALL_DIR"
  echo "  service  : systemctl status ${SERVICE_NAME}"
  echo "  watchdog : systemctl status ${SERVICE_NAME}-watchdog.timer"
  echo "  menu     : ww51"
  echo "  config   : $CONF_ENV"
  echo "  PROTO    : $proto  (change anytime: sudo ww51 edit)"
  if [[ "$side" == "ir" ]]; then
    echo "  forward  : 0.0.0.0:{${ports// /,}} -> ${kh_ip} via 10.10.0.2"
    if [[ "$encrypt" == "1" ]]; then
      echo "  encrypt  : EncryptionClient on each forward port"
      echo "  note     : on Kharej enable encryption too; panel must listen on 127.0.0.1"
    else
      echo "  note     : on Kharej, panel/xray must listen on the same ports (0.0.0.0 or 10.10.0.1)"
    fi
  else
    echo "  note     : start Kharej first, then Iran"
    if [[ "$encrypt" == "1" ]]; then
      echo -e "  ${YLW}panel    : bind to 127.0.0.1 on ports ${ports}${NC}"
      echo "            WaterWall EncryptionServer listens on 10.10.0.1"
    fi
  fi
  if [[ "$encrypt" == "1" ]]; then
    echo -e "  ${YLW}key      : ${key}${NC}"
    echo "            use the SAME key + PROTO + ports + algorithm on both servers"
    echo "  algo     : ${ENC_ALGO:-$ENC_ALGO_DEFAULT}  salt=${ENC_SALT_DEFAULT}"
    echo "            old-cpu binaries use chacha20-poly1305 (AES-GCM unavailable)"
  else
    echo "  encrypt  : off"
  fi
}

change_ports() {
  [[ -f "$CONF_ENV" ]] || err "Not installed"
  # shellcheck disable=SC1090
  source "$CONF_ENV"

  # Iran always owns forward ports. Kharej needs the same list when encryption is on.
  if [[ "${SIDE}" != "ir" && "${ENCRYPT:-0}" != "1" ]]; then
    err "Port list is edited on Iran (or enable encryption on Kharej and use Edit tunnel)"
  fi

  local ports
  read_tty -r -p "New ports (space/comma) [${PORTS}]: " ports
  ports="$(normalize_ports "${ports:-$PORTS}")"
  validate_ports "$ports" || err "Invalid ports"

  apply_tunnel_config "${SIDE}" "$IRAN_IP" "$KHAREJ_IP" "$PROTO" "${ENCRYPT:-0}" "${AES_KEY:-}" "$ports" "${OLDCPU:-0}"
  ok "Ports updated: $ports (PROTO=${PROTO})"
  if [[ "${SIDE}" == "ir" && "${ENCRYPT:-0}" == "1" ]]; then
    warn "Also update the same ports on Kharej (sudo ww51 edit) so EncryptionServer matches."
  fi
}

menu() {
  while true; do
    clear 2>/dev/null || true
    echo -e "${CYN}WaterWall Proto51 Tunnel${NC}"
    echo "========================="
    echo "1) Install / Reinstall"
    echo "2) Status"
    echo "3) Restart"
    echo "4) Edit tunnel (IPs / PROTO / ports / encryption)"
    echo "5) Change ports"
    echo "6) Uninstall"
    echo "0) Exit"
    echo
    echo -e "  Docs: ${CYN}https://radkesvat.github.io/WaterWall-Docs/docs/intro${NC}"
    echo
    read_tty -r -p "Select: " c || exit 0
    case "$c" in
      1) prompt_install ;;
      2) show_status ;;
      3) systemctl restart "$SERVICE_NAME"; show_status ;;
      4) edit_tunnel ;;
      5) change_ports ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid option" ;;
    esac
    echo
    read_tty -r -p "Press Enter to continue..." _ || true
  done
}

main() {
  need_root
  case "${1:-}" in
    install) prompt_install ;;
    status) show_status ;;
    restart) systemctl restart "$SERVICE_NAME"; show_status ;;
    edit) edit_tunnel ;;
    uninstall) uninstall_all ;;
    ports) change_ports ;;
    *) menu ;;
  esac
}

main "$@"
