#!/bin/sh
# Xray VLESS + TCP + REALITY universal manager
# v2 fixed: repair interactive prompt capture and make every setup step explicit.
# POSIX-sh implementation for low dependency usage across common Linux distributions.
# Supports interactive menu and key=value configuration workflow.

set -u
umask 077

APP_NAME="xray-reality"
APP_DIR="/usr/local/lib/${APP_NAME}"
BASE_DIR="/etc/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
XRAY_BIN="${APP_DIR}/xray"
ENV_FILE="${BASE_DIR}/reality.env"
CONFIG_FILE="${BASE_DIR}/config.json"
SHARE_FILE="${BASE_DIR}/share-link.txt"
CLIENT_FILE="${BASE_DIR}/client.json"
CLASH_FILE="${BASE_DIR}/clash-meta.yaml"
PID_FILE="/run/${APP_NAME}.pid"
SERVICE_LOG="${LOG_DIR}/service.log"
SYSTEMD_FILE="/etc/systemd/system/${APP_NAME}.service"
INIT_FILE="/etc/init.d/${APP_NAME}"
SELF_BIN="/usr/local/sbin/realityctl"

DEFAULT_PORT="443"
DEFAULT_SNI="www.apple.com"
DEFAULT_TARGET_PORT="443"
DEFAULT_NODE_NAME="Reality"
DEFAULT_LOG_LEVEL="warning"
DEFAULT_AUTO_FIREWALL="0"

OS_ID="unknown"
OS_NAME="Linux"
PKG_MGR="unknown"
INIT_MGR="manual"
XRAY_ASSET=""
ASSUME_YES="0"
CONFIG_INPUT=""
COMMAND="menu"

# Runtime configuration values.
PORT="$DEFAULT_PORT"
SNI="$DEFAULT_SNI"
TARGET_PORT="$DEFAULT_TARGET_PORT"
UUID="auto"
PRIVATE_KEY="auto"
PUBLIC_KEY="auto"
SHORT_ID="auto"
SERVER_ADDR="auto"
NODE_NAME="$DEFAULT_NODE_NAME"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
AUTO_FIREWALL="$DEFAULT_AUTO_FIREWALL"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
fi

info() { printf "%b[INFO]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf "%b[ OK ]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "%b[ERR ]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

pause_menu() {
  printf "\n按 Enter 返回菜单..."
  IFS= read -r _ans || true
}

confirm() {
  _prompt="$1"
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  printf "%s [y/N]: " "$_prompt"
  IFS= read -r _ans || _ans=""
  case "$_ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此操作。"
}

detect_platform() {
  if [ -r /etc/os-release ]; then
    OS_ID=$(sed -n 's/^ID=//p' /etc/os-release | sed 's/^"//;s/"$//' | sed -n '1p')
    OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | sed 's/^"//;s/"$//' | sed -n '1p')
    [ -n "$OS_ID" ] || OS_ID="unknown"
    [ -n "$OS_NAME" ] || OS_NAME="Linux"
  fi

  if command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
  elif command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
  elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"
  elif command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper"
  else PKG_MGR="unknown"
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_MGR="systemd"
  elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT_MGR="openrc"
  elif [ -d /etc/init.d ]; then
    INIT_MGR="sysv"
  else
    INIT_MGR="manual"
  fi
}

install_dependencies() {
  require_root
  detect_platform

  _missing=""
  for _cmd in curl unzip openssl sed grep; do
    command -v "$_cmd" >/dev/null 2>&1 || _missing="${_missing} ${_cmd}"
  done
  [ -z "$_missing" ] && { ok "基础依赖已就绪。"; return 0; }

  info "缺少依赖:${_missing}；使用 ${PKG_MGR} 安装最小依赖集。"
  case "$PKG_MGR" in
    apk)
      apk add --no-cache ca-certificates curl unzip openssl >/dev/null || die "apk 安装依赖失败。"
      command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || true
      ;;
    apt)
      apt-get update >/dev/null || die "apt-get update 失败。"
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip openssl >/dev/null || die "apt 安装依赖失败。"
      ;;
    dnf)
      dnf install -y ca-certificates curl unzip openssl >/dev/null || die "dnf 安装依赖失败。"
      ;;
    yum)
      yum install -y ca-certificates curl unzip openssl >/dev/null || die "yum 安装依赖失败。"
      ;;
    pacman)
      pacman -Sy --needed --noconfirm ca-certificates curl unzip openssl >/dev/null || die "pacman 安装依赖失败。"
      ;;
    zypper)
      zypper --non-interactive install ca-certificates curl unzip openssl >/dev/null || die "zypper 安装依赖失败。"
      ;;
    *)
      die "无法识别包管理器。请先手动安装 curl、unzip、openssl、ca-certificates 后重试。"
      ;;
  esac
  ok "依赖安装完成。"
}

detect_asset() {
  _arch=$(uname -m)
  case "$_arch" in
    x86_64|amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
    i386|i486|i586|i686|x86) XRAY_ASSET="Xray-linux-32.zip" ;;
    aarch64|arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
    armv6l|armv6) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
    ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
    s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
    riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
    mips64le) XRAY_ASSET="Xray-linux-mips64le.zip" ;;
    mips64) XRAY_ASSET="Xray-linux-mips64.zip" ;;
    *) die "暂不识别 CPU 架构：$_arch。可在 detect_asset() 中补充官方 Release 资产名。" ;;
  esac
}

download_xray() {
  require_root
  install_dependencies
  detect_asset
  mkdir -p "$APP_DIR" "$BASE_DIR" "$LOG_DIR" || die "创建目录失败。"

  _tmp=$(mktemp -d 2>/dev/null || printf '/tmp/xray-reality.%s' "$$")
  [ -d "$_tmp" ] || mkdir -p "$_tmp" || die "无法创建临时目录。"
  _zip="${_tmp}/xray.zip"
  _url="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"

  info "下载 Xray: ${XRAY_ASSET}"
  if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$_zip" "$_url"; then
    rm -rf "$_tmp"
    die "下载失败：$_url"
  fi
  mkdir -p "${_tmp}/xray"
  if ! unzip -q -o "$_zip" -d "${_tmp}/xray"; then
    rm -rf "$_tmp"; die "解压 Xray 失败。"
  fi
  [ -f "${_tmp}/xray/xray" ] || { rm -rf "$_tmp"; die "压缩包中没有 xray 可执行文件。"; }

  cp "${_tmp}/xray/xray" "${XRAY_BIN}.new" || { rm -rf "$_tmp"; die "复制 xray 失败。"; }
  chmod 0755 "${XRAY_BIN}.new"
  if ! "${XRAY_BIN}.new" version >/dev/null 2>&1; then
    rm -f "${XRAY_BIN}.new"; rm -rf "$_tmp"; die "下载的 Xray 无法运行，可能架构不匹配。"
  fi
  [ -x "$XRAY_BIN" ] && cp -f "$XRAY_BIN" "${XRAY_BIN}.bak" 2>/dev/null || true
  mv -f "${XRAY_BIN}.new" "$XRAY_BIN"

  [ -f "${_tmp}/xray/geoip.dat" ] && cp -f "${_tmp}/xray/geoip.dat" "$APP_DIR/geoip.dat"
  [ -f "${_tmp}/xray/geosite.dat" ] && cp -f "${_tmp}/xray/geosite.dat" "$APP_DIR/geosite.dat"
  rm -rf "$_tmp"

  _ver=$($XRAY_BIN version 2>/dev/null | sed -n '1p')
  ok "Xray 已安装：${_ver:-unknown version}"
}

reset_defaults() {
  PORT="$DEFAULT_PORT"
  SNI="$DEFAULT_SNI"
  TARGET_PORT="$DEFAULT_TARGET_PORT"
  UUID="auto"
  PRIVATE_KEY="auto"
  PUBLIC_KEY="auto"
  SHORT_ID="auto"
  SERVER_ADDR="auto"
  NODE_NAME="$DEFAULT_NODE_NAME"
  LOG_LEVEL="$DEFAULT_LOG_LEVEL"
  AUTO_FIREWALL="$DEFAULT_AUTO_FIREWALL"
}

strip_outer_quotes() {
  _v="$1"
  case "$_v" in
    \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
    \'*\') _v=${_v#\'}; _v=${_v%\'} ;;
  esac
  printf '%s' "$_v"
}

load_env_file() {
  _file="$1"
  [ -f "$_file" ] || return 1
  reset_defaults
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=$(printf '%s' "$_line" | sed 's/\r$//')
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *=*) ;; *) warn "忽略无效配置行：$_line"; continue ;; esac
    _key=${_line%%=*}
    _val=${_line#*=}
    _key=$(printf '%s' "$_key" | tr -d ' \t')
    _val=$(strip_outer_quotes "$_val")
    case "$_key" in
      PORT) PORT="$_val" ;;
      SNI) SNI="$_val" ;;
      TARGET_PORT) TARGET_PORT="$_val" ;;
      UUID) UUID="$_val" ;;
      PRIVATE_KEY) PRIVATE_KEY="$_val" ;;
      PUBLIC_KEY|PASSWORD) PUBLIC_KEY="$_val" ;;
      SHORT_ID) SHORT_ID="$_val" ;;
      SERVER_ADDR) SERVER_ADDR="$_val" ;;
      NODE_NAME) NODE_NAME="$_val" ;;
      LOG_LEVEL) LOG_LEVEL="$_val" ;;
      AUTO_FIREWALL) AUTO_FIREWALL="$_val" ;;
      *) warn "忽略未知配置项：$_key" ;;
    esac
  done < "$_file"
  return 0
}

safe_single_line() {
  _x=$1
  [ "$(printf '%s' "$_x" | wc -l | tr -d ' ')" -eq 0 ] 2>/dev/null
}

valid_port() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

valid_domain() {
  _d=${1:-}
  case "$_d" in
    ''|.*|*.|*/*|*:*|*' '*|*[!A-Za-z0-9._-]*) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_server_addr() {
  _a=${1:-}
  [ -n "$_a" ] || return 1
  case "$_a" in
    *' '*|*/*|*\[*|*\]*) return 1 ;;
    *[!A-Za-z0-9._:%-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_uuid() {
  _u=${1:-}
  [ "$_u" = "auto" ] && return 0
  case "$_u" in ????????-????-????-????-????????????) return 0 ;; *) return 1 ;; esac
}

valid_short_id() {
  _s=${1:-}
  [ "$_s" = "auto" ] && return 0
  _len=${#_s}
  [ "$_len" -le 16 ] || return 1
  [ $((_len % 2)) -eq 0 ] || return 1
  case "$_s" in *[!0-9a-fA-F]*) return 1 ;; *) return 0 ;; esac
}

validate_env() {
  valid_port "$PORT" || { err "PORT 必须是 1-65535。"; return 1; }
  valid_domain "$SNI" || { err "SNI 必须是纯域名，例如 www.example.com。"; return 1; }
  valid_port "$TARGET_PORT" || { err "TARGET_PORT 必须是 1-65535。"; return 1; }
  valid_uuid "$UUID" || { err "UUID 格式无效。"; return 1; }
  valid_short_id "$SHORT_ID" || { err "SHORT_ID 必须为偶数长度十六进制，最多 16 个字符。"; return 1; }
  if [ "$SERVER_ADDR" != "auto" ]; then valid_server_addr "$SERVER_ADDR" || { err "SERVER_ADDR 格式无效。"; return 1; }; fi
  case "$AUTO_FIREWALL" in 0|1) ;; *) err "AUTO_FIREWALL 只能是 0 或 1。"; return 1 ;; esac
  case "$LOG_LEVEL" in none|debug|info|warning|error) ;; *) err "LOG_LEVEL 仅支持 none/debug/info/warning/error。"; return 1 ;; esac
  [ -n "$NODE_NAME" ] || { err "NODE_NAME 不能为空。"; return 1; }
  safe_single_line "$NODE_NAME" || { err "NODE_NAME 不能包含换行。"; return 1; }
  return 0
}

save_env_file() {
  mkdir -p "$BASE_DIR" || die "无法创建 $BASE_DIR"
  _tmp="${ENV_FILE}.new"
  cat > "$_tmp" <<EOF_CFG
# Xray REALITY unified configuration
# 修改后执行: realityctl apply
PORT=${PORT}
SNI=${SNI}
TARGET_PORT=${TARGET_PORT}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SERVER_ADDR=${SERVER_ADDR}
NODE_NAME=${NODE_NAME}
LOG_LEVEL=${LOG_LEVEL}
AUTO_FIREWALL=${AUTO_FIREWALL}
EOF_CFG
  chmod 0600 "$_tmp"
  mv -f "$_tmp" "$ENV_FILE"
}

init_config() {
  require_root
  _dst=${CONFIG_INPUT:-$ENV_FILE}
  if [ -f "$_dst" ] && ! confirm "$_dst 已存在，覆盖吗？"; then return 0; fi
  mkdir -p "$(dirname "$_dst")" || die "无法创建配置目录。"
  reset_defaults
  cat > "$_dst" <<EOF_CFG
# realityctl 配置模板。可直接编辑后执行：realityctl --config $_dst install
PORT=443
SNI=www.apple.com
TARGET_PORT=443
UUID=auto
PRIVATE_KEY=auto
PUBLIC_KEY=auto
SHORT_ID=auto
SERVER_ADDR=auto
NODE_NAME=Reality
LOG_LEVEL=warning
AUTO_FIREWALL=0
EOF_CFG
  chmod 0600 "$_dst"
  ok "已生成配置模板：$_dst"
}

generate_credentials() {
  [ -x "$XRAY_BIN" ] || die "Xray 未安装。"
  info "生成 UUID / X25519 / Short ID..."
  UUID=$($XRAY_BIN uuid 2>/dev/null | tr -d '\r\n')
  [ -n "$UUID" ] || die "UUID 生成失败。"

  _keys=$($XRAY_BIN x25519 2>/dev/null) || die "X25519 生成失败。"
  PRIVATE_KEY=$(printf '%s\n' "$_keys" | sed -n \
    -e 's/^PrivateKey:[[:space:]]*//p' \
    -e 's/^Private [Kk]ey:[[:space:]]*//p' | sed -n '1p')
  PUBLIC_KEY=$(printf '%s\n' "$_keys" | sed -n \
    -e 's/^Password (PublicKey):[[:space:]]*//p' \
    -e 's/^Password:[[:space:]]*//p' \
    -e 's/^PublicKey:[[:space:]]*//p' \
    -e 's/^Public [Kk]ey:[[:space:]]*//p' | sed -n '1p')
  [ -n "$PRIVATE_KEY" ] || { printf '%s\n' "$_keys" >&2; die "无法解析 X25519 私钥。"; }
  [ -n "$PUBLIC_KEY" ] || { printf '%s\n' "$_keys" >&2; die "无法解析 X25519 Password/PublicKey。"; }
  SHORT_ID=$(openssl rand -hex 8 2>/dev/null) || die "Short ID 生成失败。"
  ok "凭据生成完成。"
}

derive_public_from_private() {
  [ -x "$XRAY_BIN" ] || return 1
  [ -n "${PRIVATE_KEY:-}" ] && [ "$PRIVATE_KEY" != "auto" ] || return 1
  _derived_out=$($XRAY_BIN x25519 -i "$PRIVATE_KEY" 2>/dev/null) || return 1
  _derived_pub=$(printf '%s\n' "$_derived_out" | sed -n \
    -e 's/^Password (PublicKey):[[:space:]]*//p' \
    -e 's/^Password:[[:space:]]*//p' \
    -e 's/^PublicKey:[[:space:]]*//p' \
    -e 's/^Public [Kk]ey:[[:space:]]*//p' | sed -n '1p')
  [ -n "$_derived_pub" ] || return 1
  printf '%s' "$_derived_pub"
}

verify_keypair() {
  _derived=$(derive_public_from_private 2>/dev/null || true)
  [ -z "$_derived" ] && return 2
  [ "$_derived" = "$PUBLIC_KEY" ]
}

resolve_auto_credentials() {
  _need_keys=0
  [ "$UUID" = "auto" ] && UUID=$($XRAY_BIN uuid 2>/dev/null | tr -d '\r\n')
  [ "$PRIVATE_KEY" = "auto" ] && _need_keys=1
  [ "$PUBLIC_KEY" = "auto" ] && _need_keys=1
  if [ "$_need_keys" -eq 1 ]; then
    _keys=$($XRAY_BIN x25519 2>/dev/null) || die "X25519 生成失败。"
    PRIVATE_KEY=$(printf '%s\n' "$_keys" | sed -n -e 's/^PrivateKey:[[:space:]]*//p' -e 's/^Private [Kk]ey:[[:space:]]*//p' | sed -n '1p')
    PUBLIC_KEY=$(printf '%s\n' "$_keys" | sed -n -e 's/^Password (PublicKey):[[:space:]]*//p' -e 's/^Password:[[:space:]]*//p' -e 's/^PublicKey:[[:space:]]*//p' -e 's/^Public [Kk]ey:[[:space:]]*//p' | sed -n '1p')
  fi
  [ "$SHORT_ID" = "auto" ] && SHORT_ID=$(openssl rand -hex 8 2>/dev/null)
  [ -n "$UUID" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] || die "自动生成凭据失败。"
}

detect_public_addr() {
  _v4=$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if valid_server_addr "$_v4" 2>/dev/null && printf '%s' "$_v4" | grep -q '\.'; then
    printf '%s' "$_v4"; return 0
  fi
  _v6=$(curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || true)
  if valid_server_addr "$_v6" 2>/dev/null && printf '%s' "$_v6" | grep -q ':'; then
    printf '%s' "$_v6"; return 0
  fi
  return 1
}

resolve_server_addr() {
  if [ "$SERVER_ADDR" = "auto" ]; then
    SERVER_ADDR=$(detect_public_addr || true)
    [ -n "$SERVER_ADDR" ] || die "无法自动获取公网地址，请在配置中设置 SERVER_ADDR。"
    ok "公网地址：$SERVER_ADDR"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

uri_fragment_escape() {
  printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g'
}

write_config_atomic() {
  [ -x "$XRAY_BIN" ] || die "Xray 未安装。"
  validate_env || die "配置校验失败。"
  mkdir -p "$BASE_DIR" "$LOG_DIR"
  chmod 0755 "$LOG_DIR"
  touch "$SERVICE_LOG" 2>/dev/null || true
  chmod 0600 "$SERVICE_LOG" 2>/dev/null || true

  _tmp="${CONFIG_FILE}.new.json"
  _sni=$(json_escape "$SNI")
  _pk=$(json_escape "$PRIVATE_KEY")
  _uuid=$(json_escape "$UUID")
  _sid=$(json_escape "$SHORT_ID")
  _log=$(json_escape "$LOG_LEVEL")

  cat > "$_tmp" <<EOF_JSON
{
  "log": {
    "error": "${SERVICE_LOG}",
    "loglevel": "${_log}"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${_uuid}", "flow": "xtls-rprx-vision", "email": "reality"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${_sni}:${TARGET_PORT}",
          "xver": 0,
          "serverNames": ["${_sni}"],
          "privateKey": "${_pk}",
          "shortIds": ["${_sid}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
EOF_JSON
  chmod 0600 "$_tmp"

  info "执行 Xray 配置自检..."
  if "$XRAY_BIN" run -test -c "$_tmp" >/dev/null 2>"${BASE_DIR}/config-test.err"; then
    [ -f "$CONFIG_FILE" ] && cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    mv -f "$_tmp" "$CONFIG_FILE"
    rm -f "${BASE_DIR}/config-test.err"
    ok "config.json 检查通过。"
  else
    err "Xray 拒绝新配置，原配置未被覆盖。"
    cat "${BASE_DIR}/config-test.err" >&2 2>/dev/null || true
    rm -f "$_tmp"
    return 1
  fi
}

write_client_files() {
  _addr=$(json_escape "$SERVER_ADDR")
  _uuid=$(json_escape "$UUID")
  _sni=$(json_escape "$SNI")
  _pub=$(json_escape "$PUBLIC_KEY")
  _sid=$(json_escape "$SHORT_ID")
  _name=$(yaml_escape "$NODE_NAME")

  case "$SERVER_ADDR" in *:*) _link_addr="[$SERVER_ADDR]" ;; *) _link_addr="$SERVER_ADDR" ;; esac
  _link_name=$(uri_fragment_escape "$NODE_NAME")
  _link="vless://${UUID}@${_link_addr}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${_link_name}"
  printf '%s\n' "$_link" > "$SHARE_FILE"
  chmod 0600 "$SHARE_FILE"

  cat > "$CLIENT_FILE" <<EOF_CLIENT
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}}
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {"vnext": [{"address": "${_addr}", "port": ${PORT}, "users": [{"id": "${_uuid}", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {"fingerprint": "chrome", "serverName": "${_sni}", "password": "${_pub}", "shortId": "${_sid}", "spiderX": "/"}
      }
    },
    {"tag": "direct", "protocol": "freedom"}
  ]
}
EOF_CLIENT
  chmod 0600 "$CLIENT_FILE"

  cat > "$CLASH_FILE" <<EOF_CLASH
proxies:
  - name: "${_name}"
    type: vless
    server: ${SERVER_ADDR}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
EOF_CLASH
  chmod 0600 "$CLASH_FILE"
}

write_systemd_service() {
  cat > "$SYSTEMD_FILE" <<EOF_SYSTEMD
[Unit]
Description=Xray VLESS REALITY
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
  chmod 0644 "$SYSTEMD_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$APP_NAME" >/dev/null 2>&1 || true
}

write_openrc_service() {
  cat > "$INIT_FILE" <<EOF_OPENRC
#!/sbin/openrc-run
name="${APP_NAME}"
description="Xray VLESS REALITY"
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="${PID_FILE}"
output_log="${SERVICE_LOG}"
error_log="${SERVICE_LOG}"
depend() { need net; after firewall; }
EOF_OPENRC
  chmod 0755 "$INIT_FILE"
  rc-update add "$APP_NAME" default >/dev/null 2>&1 || true
}

write_sysv_service() {
  cat > "$INIT_FILE" <<EOF_SYSV
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${APP_NAME}
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Xray VLESS REALITY
### END INIT INFO
BIN="${XRAY_BIN}"
CFG="${CONFIG_FILE}"
PID="${PID_FILE}"
LOG="${SERVICE_LOG}"
case "\${1:-}" in
  start)
    [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null && exit 0
    nohup "\$BIN" run -c "\$CFG" >>"\$LOG" 2>&1 & echo \$! > "\$PID"
    ;;
  stop)
    if [ -f "\$PID" ]; then kill "\$(cat "\$PID")" 2>/dev/null || true; rm -f "\$PID"; fi
    ;;
  restart) "\$0" stop; sleep 1; "\$0" start ;;
  status) [ -f "\$PID" ] && kill -0 "\$(cat "\$PID")" 2>/dev/null ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF_SYSV
  chmod 0755 "$INIT_FILE"
  command -v update-rc.d >/dev/null 2>&1 && update-rc.d "$APP_NAME" defaults >/dev/null 2>&1 || true
  command -v chkconfig >/dev/null 2>&1 && chkconfig "$APP_NAME" on >/dev/null 2>&1 || true
}

write_service() {
  detect_platform
  case "$INIT_MGR" in
    systemd) write_systemd_service ;;
    openrc) write_openrc_service ;;
    sysv) write_sysv_service ;;
    manual) warn "未检测到 systemd/OpenRC/SysV，将使用手动 PID 模式；无法保证开机自启。" ;;
  esac
}

service_is_running() {
  detect_platform
  case "$INIT_MGR" in
    systemd) systemctl is-active --quiet "$APP_NAME" 2>/dev/null ;;
    openrc) rc-service "$APP_NAME" status >/dev/null 2>&1 ;;
    sysv) [ -x "$INIT_FILE" ] && "$INIT_FILE" status >/dev/null 2>&1 ;;
    manual) [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null ;;
  esac
}

service_stop() {
  detect_platform
  case "$INIT_MGR" in
    systemd) systemctl stop "$APP_NAME" >/dev/null 2>&1 || true ;;
    openrc) rc-service "$APP_NAME" stop >/dev/null 2>&1 || true ;;
    sysv) [ -x "$INIT_FILE" ] && "$INIT_FILE" stop >/dev/null 2>&1 || true ;;
    manual)
      if [ -f "$PID_FILE" ]; then kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null || true; rm -f "$PID_FILE"; fi
      ;;
  esac
}

service_start() {
  detect_platform
  case "$INIT_MGR" in
    systemd) systemctl start "$APP_NAME" ;;
    openrc) rc-service "$APP_NAME" start ;;
    sysv) "$INIT_FILE" start ;;
    manual)
      [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && return 0
      nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >>"$SERVICE_LOG" 2>&1 & echo $! > "$PID_FILE"
      ;;
  esac
}

service_restart() {
  service_stop
  sleep 1
  service_start || return 1
  sleep 1
  if service_is_running; then ok "Xray 服务运行正常。"; return 0; fi
  err "服务启动失败。请运行：realityctl diagnose"
  return 1
}

apply_firewall() {
  [ "$AUTO_FIREWALL" = "1" ] || return 0
  info "AUTO_FIREWALL=1：尝试放行 TCP/${PORT}。"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || warn "firewalld 添加规则失败。"
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "已处理 firewalld 规则。"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || warn "ufw 添加规则失败。"
    ok "已处理 ufw 规则。"
  else
    warn "未发现正在运行的 ufw/firewalld；不会自动启用防火墙。请确认云防火墙/NAT 已放行 TCP/${PORT}。"
  fi
}

port_is_listening() {
  _p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -E "[:.]${_p}[[:space:]]" >/dev/null 2>&1 && return 0
  fi
  _hex=$(printf '%04X' "$_p" 2>/dev/null || true)
  [ -n "$_hex" ] || return 1
  grep -Eqi ":${_hex}[[:space:]].*[[:space:]]0A[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

test_target_quiet() {
  [ -x "$XRAY_BIN" ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 "$XRAY_BIN" tls ping "${SNI}:${TARGET_PORT}" >/dev/null 2>&1 && return 0
  fi
  curl -fsSI --connect-timeout 6 --max-time 10 "https://${SNI}:${TARGET_PORT}/" >/dev/null 2>&1
}

install_self() {
  _src=$0
  case "$_src" in /*) ;; *) _src=$(pwd)/$_src ;; esac
  if [ -f "$_src" ] && [ -r "$_src" ] && [ "$_src" != "$SELF_BIN" ]; then
    cp -f "$_src" "$SELF_BIN" 2>/dev/null && chmod 0755 "$SELF_BIN" 2>/dev/null || true
  fi
}

apply_loaded_config() {
  validate_env || die "配置无效。"
  [ -x "$XRAY_BIN" ] || die "Xray 未安装，请先执行 install。"
  resolve_auto_credentials
  resolve_server_addr
  validate_env || die "自动补全后的配置无效。"
  verify_keypair
  _kp=$?
  if [ "$_kp" -eq 1 ]; then die "PRIVATE_KEY 与 PUBLIC_KEY 不匹配，请重新生成密钥或修正配置。"; fi
  [ "$_kp" -eq 2 ] && warn "当前内核无法派生公钥，跳过密钥对一致性检查。"
  save_env_file
  write_config_atomic || return 1
  write_client_files
  write_service
  apply_firewall
  service_restart || return 1
  return 0
}

apply_config() {
  require_root
  _src=${CONFIG_INPUT:-$ENV_FILE}
  load_env_file "$_src" || die "找不到配置文件：$_src"
  apply_loaded_config || die "应用配置失败。"
  ok "配置已应用。"
}

# 交互输入使用全局 ASK_VALUE_RESULT 返回结果。
# 不要使用 PORT=$(ask_value ...) 这类命令替换：命令替换会把 stdout 上的
# 提示文字也一起捕获到变量里，导致类似“监听端口 [443]: 443”被当成端口。
ASK_VALUE_RESULT=""
ask_value() {
  _label=$1
  _default=$2

  if [ -n "$_default" ]; then
    printf "%s [%s]: " "$_label" "$_default"
  else
    printf "%s: " "$_label"
  fi

  IFS= read -r _in || _in=""
  if [ -n "$_in" ]; then
    ASK_VALUE_RESULT=$_in
  else
    ASK_VALUE_RESULT=$_default
  fi
}

interactive_configure_values() {
  printf "\n============================================\n"
  printf " REALITY 配置向导\n"
  printf " 直接按 Enter = 使用方括号中的默认值\n"
  printf "============================================\n\n"

  while :; do
    ask_value "[1/6] Xray/REALITY 监听端口（客户端连接此端口）" "$PORT"
    PORT=$ASK_VALUE_RESULT
    valid_port "$PORT" && break
    warn "监听端口必须是 1-65535，例如 443、8443、2053。"
  done

  while :; do
    ask_value "[2/6] REALITY SNI/Target 域名（不要带 https://）" "$SNI"
    SNI=$ASK_VALUE_RESULT
    SNI=${SNI#https://}; SNI=${SNI#http://}; SNI=${SNI%%/*}
    valid_domain "$SNI" && break
    warn "请输入纯域名，例如 www.apple.com。"
  done

  while :; do
    ask_value "[3/6] REALITY Target HTTPS 端口（一般保持 443）" "$TARGET_PORT"
    TARGET_PORT=$ASK_VALUE_RESULT
    valid_port "$TARGET_PORT" && break
    warn "Target 端口必须是 1-65535，一般填写 443。"
  done


  _detected=$(detect_public_addr || true)
  [ -n "$_detected" ] && _addr_default="$_detected" || _addr_default="$SERVER_ADDR"
  [ "$_addr_default" = "auto" ] && _addr_default=""
  while :; do
    ask_value "[4/6] 客户端连接使用的公网 IP/域名" "$_addr_default"
    SERVER_ADDR=$ASK_VALUE_RESULT
    [ -z "$SERVER_ADDR" ] && SERVER_ADDR="auto"
    if [ "$SERVER_ADDR" = "auto" ]; then
      break
    fi
    if valid_server_addr "$SERVER_ADDR"; then
      break
    fi
    warn "服务器地址格式无效，请输入 IPv4、IPv6 或域名。"
  done

  ask_value "[5/6] 节点名称" "$NODE_NAME"
  NODE_NAME=$ASK_VALUE_RESULT
  [ -n "$NODE_NAME" ] || NODE_NAME="$DEFAULT_NODE_NAME"

  ask_value "[6/6] 自动放行已启用的 ufw/firewalld？0=否 1=是" "$AUTO_FIREWALL"
  _fw=$ASK_VALUE_RESULT
  case "$_fw" in
    1|y|Y|yes|YES) AUTO_FIREWALL=1 ;;
    *) AUTO_FIREWALL=0 ;;
  esac

  printf "\n--------------------------------------------\n"
  printf " 即将应用的配置\n"
  printf "--------------------------------------------\n"
  printf "监听端口       : %s\n" "$PORT"
  printf "SNI/Target     : %s:%s\n" "$SNI" "$TARGET_PORT"
  printf "服务器地址     : %s\n" "$SERVER_ADDR"
  printf "节点名称       : %s\n" "$NODE_NAME"
  printf "自动防火墙     : %s\n" "$AUTO_FIREWALL"
  printf "--------------------------------------------\n\n"
}

interactive_install() {
  require_root
  detect_platform
  printf "\n系统: %s\n包管理器: %s\n服务管理: %s\n\n" "$OS_NAME" "$PKG_MGR" "$INIT_MGR"
  install_dependencies
  service_stop
  download_xray

  if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE" || reset_defaults
    if confirm "检测到现有配置，保留 UUID/Reality 密钥吗？"; then :; else UUID="auto"; PRIVATE_KEY="auto"; PUBLIC_KEY="auto"; SHORT_ID="auto"; fi
  else
    reset_defaults
  fi

  interactive_configure_values
  resolve_auto_credentials
  resolve_server_addr
  if test_target_quiet; then ok "SNI/target 基础连通测试通过。"; else warn "SNI/target 测试未通过；仍可保存，建议稍后运行 diagnose 检查。"; fi
  apply_loaded_config || die "安装/配置失败。"
  install_self
  show_summary
  show_link
}

noninteractive_install() {
  require_root
  install_dependencies
  service_stop
  download_xray
  _src=${CONFIG_INPUT:-$ENV_FILE}
  if [ -f "$_src" ]; then load_env_file "$_src" || die "读取配置失败：$_src"; else reset_defaults; fi
  apply_loaded_config || die "安装/配置失败。"
  install_self
  ok "安装完成。"
}

guided_modify() {
  require_root
  load_env_file "$ENV_FILE" || die "尚未安装或没有 $ENV_FILE"
  interactive_configure_values
  if test_target_quiet; then ok "SNI/target 基础连通测试通过。"; else warn "SNI/target 测试未通过，建议运行 diagnose。"; fi
  apply_loaded_config || die "修改配置失败。"
  show_summary
}

rotate_credentials() {
  require_root
  load_env_file "$ENV_FILE" || die "没有现有配置。"
  confirm "重新生成凭据后旧客户端会失效，继续吗？" || return 0
  generate_credentials
  apply_loaded_config || die "轮换凭据失败。"
  show_link
}

update_core() {
  require_root
  _old=""
  [ -x "$XRAY_BIN" ] && _old=$($XRAY_BIN version 2>/dev/null | sed -n '1p')
  service_stop
  download_xray
  if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE" || die "读取配置失败。"
    if ! write_config_atomic; then
      warn "新版内核无法通过现有配置测试，尝试回滚旧内核。"
      if [ -x "${XRAY_BIN}.bak" ]; then cp -f "${XRAY_BIN}.bak" "$XRAY_BIN"; service_restart || true; fi
      die "更新未完成。"
    fi
    write_service
    service_restart || die "更新后服务启动失败。"
  fi
  _new=$($XRAY_BIN version 2>/dev/null | sed -n '1p')
  printf "旧版本: %s\n新版本: %s\n" "${_old:-未安装}" "${_new:-unknown}"
}

show_summary() {
  detect_platform
  printf "\n============================================\n"
  printf " Xray REALITY 状态\n"
  printf "============================================\n"
  printf "系统           : %s\n" "$OS_NAME"
  printf "包管理器       : %s\n" "$PKG_MGR"
  printf "服务管理       : %s\n" "$INIT_MGR"
  if [ -x "$XRAY_BIN" ]; then printf "Xray           : %s\n" "$($XRAY_BIN version 2>/dev/null | sed -n '1p')"; else printf "Xray           : 未安装\n"; fi
  if load_env_file "$ENV_FILE" 2>/dev/null; then
    printf "节点名称       : %s\n" "$NODE_NAME"
    printf "服务器地址     : %s\n" "$SERVER_ADDR"
    printf "监听端口       : %s\n" "$PORT"
    printf "SNI/target     : %s:%s\n" "$SNI" "$TARGET_PORT"
    printf "UUID           : %s\n" "$UUID"
    printf "Short ID       : %s\n" "$SHORT_ID"
    printf "配置文件       : %s\n" "$ENV_FILE"
  fi
  if service_is_running; then printf "服务           : 运行中\n"; else printf "服务           : 未运行\n"; fi
  printf "============================================\n"
}

show_link() {
  [ -f "$SHARE_FILE" ] || die "分享链接不存在，请先安装/应用配置。"
  printf "\n分享链接（包含连接凭据，请勿公开）：\n\n"
  cat "$SHARE_FILE"
  printf "\n"
  if command -v qrencode >/dev/null 2>&1 && [ -t 1 ]; then
    printf "\n二维码：\n"
    qrencode -t ANSIUTF8 < "$SHARE_FILE" 2>/dev/null || true
  fi
}

show_logs() {
  detect_platform
  case "$INIT_MGR" in
    systemd) journalctl -u "$APP_NAME" -n 80 --no-pager 2>/dev/null || true ;;
    *) tail -n 80 "$SERVICE_LOG" 2>/dev/null || true ;;
  esac
}

DIAG_OK=0; DIAG_WARN=0; DIAG_FAIL=0
diag_ok() { DIAG_OK=$((DIAG_OK + 1)); ok "$*"; }
diag_warn() { DIAG_WARN=$((DIAG_WARN + 1)); warn "$*"; }
diag_fail() { DIAG_FAIL=$((DIAG_FAIL + 1)); err "$*"; }

diagnose() {
  require_root
  detect_platform
  DIAG_OK=0; DIAG_WARN=0; DIAG_FAIL=0
  printf "\n========== REALITY 自检 / 诊断 ==========\n"
  printf "系统: %s | arch=%s | pkg=%s | init=%s\n\n" "$OS_NAME" "$(uname -m)" "$PKG_MGR" "$INIT_MGR"

  for _cmd in curl unzip openssl sed grep; do
    command -v "$_cmd" >/dev/null 2>&1 && diag_ok "依赖 $_cmd 可用" || diag_fail "缺少依赖 $_cmd"
  done

  if [ -x "$XRAY_BIN" ]; then
    diag_ok "Xray 可执行：$($XRAY_BIN version 2>/dev/null | sed -n '1p')"
  else
    diag_fail "Xray 未安装：$XRAY_BIN"
  fi

  if load_env_file "$ENV_FILE"; then
    if validate_env; then diag_ok "reality.env 字段校验通过"; else diag_fail "reality.env 字段有误"; fi
  else
    diag_fail "找不到 $ENV_FILE"
  fi

  if [ -x "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
    if "$XRAY_BIN" run -test -c "$CONFIG_FILE" >/tmp/xray-reality-test.$$ 2>&1; then
      diag_ok "config.json 语法/内核校验通过"
      _stale=0
      grep -Fq '"port": '"$PORT" "$CONFIG_FILE" 2>/dev/null || _stale=1
      grep -Fq '"target": "'"$SNI:$TARGET_PORT"'"' "$CONFIG_FILE" 2>/dev/null || _stale=1
      grep -Fq '"id": "'"$UUID"'"' "$CONFIG_FILE" 2>/dev/null || _stale=1
      grep -Fq '"shortIds": ["'"$SHORT_ID"'"]' "$CONFIG_FILE" 2>/dev/null || _stale=1
      if [ "$_stale" -eq 0 ]; then diag_ok "reality.env 与 config.json 关键字段一致"; else diag_warn "reality.env 与 config.json 可能不同步，请执行 realityctl apply"; fi
      verify_keypair
      _kp=$?
      if [ "$_kp" -eq 0 ]; then diag_ok "X25519 私钥与客户端 Password/PublicKey 匹配"
      elif [ "$_kp" -eq 1 ]; then diag_fail "X25519 PRIVATE_KEY 与 PUBLIC_KEY 不匹配"
      else diag_warn "当前内核无法派生公钥，未检查密钥对一致性"; fi
    else
      diag_fail "config.json 校验失败"
      tail -n 12 /tmp/xray-reality-test.$$ 2>/dev/null || true
    fi
    rm -f /tmp/xray-reality-test.$$ 2>/dev/null || true
  else
    diag_fail "无法执行 config.json 测试"
  fi

  if service_is_running; then diag_ok "服务正在运行"; else diag_fail "服务未运行"; fi

  if valid_port "${PORT:-}" 2>/dev/null; then
    if port_is_listening "$PORT"; then diag_ok "TCP/${PORT} 正在监听"; else diag_fail "TCP/${PORT} 未监听"; fi
  fi

  if valid_domain "${SNI:-}" 2>/dev/null; then
    if test_target_quiet; then
      diag_ok "SNI/target ${SNI}:${TARGET_PORT} 可建立基础 TLS/REALITY 探测"
    else
      diag_warn "SNI/target ${SNI}:${TARGET_PORT} 探测失败：检查 DNS、出站 443、目标站点或更换 SNI"
    fi
  fi

  _public=$(detect_public_addr || true)
  if [ -n "$_public" ]; then
    diag_ok "当前出口公网地址：$_public"
    case "$SERVER_ADDR" in
      auto) diag_warn "SERVER_ADDR 仍为 auto，建议执行 apply 固化配置" ;;
      *:*) [ "$SERVER_ADDR" = "$_public" ] || diag_warn "配置地址与探测地址不同；若使用 NAT/域名/端口映射可忽略" ;;
      *.*) [ "$SERVER_ADDR" = "$_public" ] || diag_warn "配置地址与探测地址不同；若使用 NAT/域名/端口映射可忽略" ;;
    esac
  else
    diag_warn "无法探测公网地址（可能仅内网、出口受限或探测站不可达）"
  fi

  if command -v getenforce >/dev/null 2>&1; then
    _se=$(getenforce 2>/dev/null || true)
    [ "$_se" = "Enforcing" ] && diag_warn "SELinux=Enforcing；本脚本不会自动关闭它，如服务报权限错误请检查审计日志" || diag_ok "SELinux 状态：${_se:-unknown}"
  fi

  if [ "$AUTO_FIREWALL" = "0" ]; then
    diag_warn "AUTO_FIREWALL=0：请自行确认云防火墙/NAT/主机防火墙已放行 TCP/${PORT}"
  fi

  if [ -s "$SERVICE_LOG" ]; then
    _errs=$(tail -n 60 "$SERVICE_LOG" 2>/dev/null | grep -Ei 'failed|error|panic|rejected|invalid' | tail -n 5 || true)
    if [ -n "$_errs" ]; then
      diag_warn "最近日志包含可疑关键字："
      printf '%s\n' "$_errs"
    else
      diag_ok "最近服务日志未发现常见错误关键字"
    fi
  fi

  printf "\n诊断汇总：OK=%s WARN=%s FAIL=%s\n" "$DIAG_OK" "$DIAG_WARN" "$DIAG_FAIL"
  if [ "$DIAG_FAIL" -gt 0 ]; then
    printf "建议顺序：先修复 FAIL → 执行 realityctl apply → 再运行 realityctl diagnose。\n"
    return 1
  fi
  return 0
}

edit_config() {
  require_root
  [ -f "$ENV_FILE" ] || init_config
  _editor=${EDITOR:-}
  if [ -z "$_editor" ]; then
    if command -v vi >/dev/null 2>&1; then _editor=vi
    elif command -v nano >/dev/null 2>&1; then _editor=nano
    else warn "未找到 vi/nano。请手动编辑：$ENV_FILE"; return 0
    fi
  fi
  "$_editor" "$ENV_FILE"
  if confirm "现在校验并应用修改吗？"; then apply_config; fi
}

toggle_debug() {
  require_root
  load_env_file "$ENV_FILE" || die "没有现有配置。"
  if [ "$LOG_LEVEL" = "debug" ]; then LOG_LEVEL="warning"; else LOG_LEVEL="debug"; fi
  apply_loaded_config || die "切换日志级别失败。"
  ok "LOG_LEVEL=${LOG_LEVEL}"
}

uninstall_all() {
  require_root
  confirm "确认卸载 ${APP_NAME}？配置和客户端文件也会删除。" || return 0
  service_stop
  detect_platform
  case "$INIT_MGR" in
    systemd)
      systemctl disable "$APP_NAME" >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_FILE"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc) rc-update del "$APP_NAME" default >/dev/null 2>&1 || true; rm -f "$INIT_FILE" ;;
    sysv)
      command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$APP_NAME" remove >/dev/null 2>&1 || true
      command -v chkconfig >/dev/null 2>&1 && chkconfig --del "$APP_NAME" >/dev/null 2>&1 || true
      rm -f "$INIT_FILE"
      ;;
  esac
  rm -rf "$APP_DIR" "$BASE_DIR" "$LOG_DIR"
  rm -f "$PID_FILE" "$SELF_BIN"
  ok "已卸载。系统依赖包未删除。"
}

print_help() {
  cat <<EOF_HELP
Usage: $0 [--config FILE] [--yes] COMMAND

Commands:
  menu            交互式管理菜单（默认）
  install         安装/重装；带 --config 时为配置文件驱动模式
  init-config     生成可编辑配置模板
  apply           读取配置、校验、重建客户端文件并重启服务
  configure       交互式修改端口/SNI/地址/节点名
  rotate          重新生成 UUID/X25519/Short ID
  update          更新 Xray Core，失败时尽量回滚
  diagnose        自检：依赖、配置、服务、端口、target、公网地址
  status          查看当前状态
  link            显示 VLESS 分享链接；已安装 qrencode 时顺便显示二维码
  logs            查看最近服务日志
  edit            用 EDITOR/vi/nano 修改 reality.env，随后可立即 apply
  debug           在 warning/debug 日志级别之间切换
  uninstall       卸载本脚本管理的 Xray REALITY
  help            显示本帮助

配置文件默认位置: $ENV_FILE
安装后管理命令:   realityctl

示例：
  $0 init-config --config /root/reality.env
  vi /root/reality.env
  $0 install --config /root/reality.env --yes
  realityctl diagnose
EOF_HELP
}

menu() {
  require_root
  while :; do
    detect_platform
    printf "\n============================================\n"
    printf " Xray VLESS + TCP + REALITY 通用管理\n"
    printf " %s | %s | %s\n" "$OS_ID" "$PKG_MGR" "$INIT_MGR"
    printf "============================================\n"
    printf "1. 安装 / 重装（交互配置）\n"
    printf "2. 修改配置（交互）\n"
    printf "3. 应用 reality.env\n"
    printf "4. 编辑 reality.env\n"
    printf "5. 重新生成 UUID / Reality 密钥\n"
    printf "6. 更新 Xray Core\n"
    printf "7. 自检 / 故障诊断\n"
    printf "8. 查看状态\n"
    printf "9. 显示分享链接 / 二维码\n"
    printf "10. 查看日志\n"
    printf "11. 切换 Debug\n"
    printf "12. 卸载\n"
    printf "0. 退出\n"
    printf "============================================\n"
    printf "请选择: "
    IFS= read -r _choice || _choice=0
    case "$_choice" in
      1) interactive_install; pause_menu ;;
      2) guided_modify; pause_menu ;;
      3) apply_config; pause_menu ;;
      4) edit_config; pause_menu ;;
      5) rotate_credentials; pause_menu ;;
      6) update_core; pause_menu ;;
      7) diagnose || true; pause_menu ;;
      8) show_summary; pause_menu ;;
      9) show_link; pause_menu ;;
      10) show_logs; pause_menu ;;
      11) toggle_debug; pause_menu ;;
      12) uninstall_all; pause_menu ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

parse_args() {
  COMMAND="menu"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        [ "$#" -ge 2 ] || die "--config 需要文件路径。"
        CONFIG_INPUT=$2; shift 2 ;;
      --config=*) CONFIG_INPUT=${1#--config=}; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      menu|install|init-config|apply|configure|rotate|update|diagnose|status|link|logs|edit|debug|uninstall|help|-h|--help)
        COMMAND=$1; shift ;;
      *) die "未知参数：$1（使用 --help 查看用法）" ;;
    esac
  done
}

main() {
  parse_args "$@"
  detect_platform
  case "$COMMAND" in
    help|-h|--help) print_help ;;
    menu) menu ;;
    install)
      if [ -n "$CONFIG_INPUT" ] || [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then noninteractive_install; else interactive_install; fi
      ;;
    init-config) init_config ;;
    apply) apply_config ;;
    configure) guided_modify ;;
    rotate) rotate_credentials ;;
    update) update_core ;;
    diagnose) diagnose ;;
    status) show_summary ;;
    link) show_link ;;
    logs) show_logs ;;
    edit) edit_config ;;
    debug) toggle_debug ;;
    uninstall) uninstall_all ;;
    *) print_help; exit 2 ;;
  esac
}

main "$@"
