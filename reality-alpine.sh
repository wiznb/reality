#!/usr/bin/env bash
set -Eeuo pipefail

# Reality / Xray Alpine 管理脚本
# 功能：安装、显示配置、修改配置、删除配置、日志管理、状态检测

XRAY_DIR="/root/Xray"
XRAY_BIN="${XRAY_DIR}/xray"
CONFIG_FILE="${XRAY_DIR}/config.json"
ENV_FILE="${XRAY_DIR}/reality.env"
SHARE_FILE="${XRAY_DIR}/share-link.txt"
CLASH_FILE="${XRAY_DIR}/clash-meta.yaml"
LOG_DIR="${XRAY_DIR}/logs"
SERVICE_FILE="/etc/init.d/xray"

red() { echo -e "\033[31m\033[01m$*\033[0m"; }
green() { echo -e "\033[32m\033[01m$*\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
plain() { echo -e "$*"; }

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    red "请使用 root 用户执行本脚本"
    exit 1
  fi
}

pause() {
  read -rp "按回车继续..." _ || true
}

ensure_dirs() {
  mkdir -p "$XRAY_DIR" "$LOG_DIR"
  touch "$LOG_DIR/access.log" "$LOG_DIR/error.log" "$LOG_DIR/service.out.log" "$LOG_DIR/service.err.log"
}

install_deps() {
  if command -v apk >/dev/null 2>&1; then
    yellow "正在安装/检查依赖..."
    apk add --no-cache bash wget unzip openrc ca-certificates curl coreutils iproute2 grep sed awk >/dev/null || true
    update-ca-certificates >/dev/null 2>&1 || true
  else
    yellow "未检测到 apk，本脚本主要面向 Alpine；将继续尝试执行。"
  fi
}

service_cmd() {
  local action="$1"
  if command -v rc-service >/dev/null 2>&1; then
    rc-service xray "$action"
  else
    service xray "$action"
  fi
}

mask_value() {
  local v="${1:-}"
  local n=${#v}
  if (( n <= 12 )); then
    printf '%s' "$v"
  else
    printf '%s...%s' "${v:0:6}" "${v:n-6:6}"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

yaml_escape() {
  json_escape "$1"
}

shell_quote() {
  printf '%q' "$1"
}

normalize_domain() {
  local d="${1:-}"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%%:*}"
  printf '%s' "$d"
}

validate_domain() {
  local d="$1"
  [[ -n "$d" && ! "$d" =~ [[:space:]/] ]]
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

port_is_available() {
  local p="$1"
  local current="${PORT:-}"
  if [[ -n "$current" && "$p" == "$current" ]]; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    # 如果端口被 xray 当前进程占用，而且是当前端口，上面已放行；其他占用视为不可用。
    ! ss -lnt | awk '{print $4}' | grep -qE "(^|:)${p}$"
  else
    return 0
  fi
}

get_public_ip() {
  local ip=""
  ip="$(wget -qO- --no-check-certificate -U Mozilla https://api.ip.sb/ip 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(wget -qO- --no-check-certificate -U Mozilla https://ifconfig.me 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsSL --connect-timeout 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  printf '%s' "$ip"
}

detect_arch() {
  local arch_raw
  arch_raw="$(uname -m)"
  case "$arch_raw" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    i386|i686) XRAY_ARCH="32" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l|armv7*) XRAY_ARCH="arm32-v7a" ;;
    armv6l|armv6*) XRAY_ARCH="arm32-v6" ;;
    *) red "暂不支持的 CPU 架构：$arch_raw"; exit 1 ;;
  esac
  ARCH_RAW="$arch_raw"
}

install_or_update_xray() {
  ensure_dirs
  detect_arch
  local zip_name="Xray-linux-${XRAY_ARCH}.zip"
  local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/${zip_name}"

  yellow "当前 CPU 架构：${ARCH_RAW}，下载文件：${zip_name}"
  yellow "下载地址：${download_url}"

  rm -f "/tmp/${zip_name}"
  if ! wget --no-check-certificate -O "/tmp/${zip_name}" "$download_url"; then
    red "下载失败，请检查服务器是否能访问 github.com"
    exit 1
  fi

  unzip -o "/tmp/${zip_name}" -d "$XRAY_DIR" >/dev/null
  rm -f "/tmp/${zip_name}"
  chmod +x "$XRAY_BIN"

  green "Xray 下载/更新成功！"
  "$XRAY_BIN" version || true
}

parse_existing_config() {
  PORT="" UUID="" DEST_SERVER="" PRIVATE_KEY="" PUBLIC_KEY="" SHORT_ID="" SERVER_IP="" NODE_NAME="32M-Reality" LOG_LEVEL="warning"

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE" || true
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    [[ -z "${PORT:-}" ]] && PORT="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -z "${UUID:-}" ]] && UUID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -z "${DEST_SERVER:-}" ]] && DEST_SERVER="$(sed -n 's/.*"dest"[[:space:]]*:[[:space:]]*"\([^":]*\):443".*/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -z "${PRIVATE_KEY:-}" ]] && PRIVATE_KEY="$(sed -n 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -z "${SHORT_ID:-}" ]] && SHORT_ID="$(awk '/"shortIds"/{getline; gsub(/[",[:space:]]/,"",$0); print; exit}' "$CONFIG_FILE")"
    [[ -z "${LOG_LEVEL:-}" || "${LOG_LEVEL:-}" == "warning" ]] && LOG_LEVEL="$(sed -n 's/.*"loglevel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
    [[ -z "${LOG_LEVEL:-}" ]] && LOG_LEVEL="warning"
  fi

  if [[ -f "$SHARE_FILE" ]]; then
    [[ -z "${PUBLIC_KEY:-}" ]] && PUBLIC_KEY="$(sed -n 's/.*[?&]pbk=\([^&]*\).*/\1/p' "$SHARE_FILE" | head -n1)"
    [[ -z "${SHORT_ID:-}" ]] && SHORT_ID="$(sed -n 's/.*[?&]sid=\([^&]*\).*/\1/p' "$SHARE_FILE" | head -n1)"
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="$(sed -n 's#^vless://[^@]*@\([^:]*\):[0-9][0-9]*.*#\1#p' "$SHARE_FILE" | head -n1)"
    local remark
    remark="$(awk -F'#' 'NF>1 {print $NF; exit}' "$SHARE_FILE")"
    [[ -n "$remark" && "${NODE_NAME:-}" == "32M-Reality" ]] && NODE_NAME="$remark"
  fi

  if [[ -f "$CLASH_FILE" ]]; then
    [[ -z "${PUBLIC_KEY:-}" ]] && PUBLIC_KEY="$(sed -n 's/.*public-key:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$CLASH_FILE" | head -n1)"
    [[ -z "${DEST_SERVER:-}" ]] && DEST_SERVER="$(sed -n 's/.*servername:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$CLASH_FILE" | head -n1)"
  fi

  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP="$(get_public_ip || true)"
  fi
}

has_config() {
  [[ -f "$CONFIG_FILE" ]] || [[ -f "$ENV_FILE" ]] || [[ -f "$SHARE_FILE" ]] || [[ -f "$CLASH_FILE" ]]
}

write_env() {
  cat > "$ENV_FILE" <<EOF_ENV
PORT=$(shell_quote "${PORT}")
UUID=$(shell_quote "${UUID}")
DEST_SERVER=$(shell_quote "${DEST_SERVER}")
PRIVATE_KEY=$(shell_quote "${PRIVATE_KEY}")
PUBLIC_KEY=$(shell_quote "${PUBLIC_KEY}")
SHORT_ID=$(shell_quote "${SHORT_ID}")
SERVER_IP=$(shell_quote "${SERVER_IP}")
NODE_NAME=$(shell_quote "${NODE_NAME}")
LOG_LEVEL=$(shell_quote "${LOG_LEVEL}")
EOF_ENV
  chmod 600 "$ENV_FILE"
}

generate_keys() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    install_or_update_xray
  fi

  local key_output
  key_output="$($XRAY_BIN x25519 2>&1 || true)"
  yellow "x25519 原始输出："
  echo "$key_output"

  PRIVATE_KEY="$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /private[[:space:]]*key|privatekey/ {print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /public[[:space:]]*key|publickey|password/ {print $2; exit}')"
  SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    red "生成 REALITY 密钥失败：private_key 或 public_key 为空。"
    red "请把上面的 x25519 原始输出发给我排查。"
    exit 1
  fi
}

write_config() {
  ensure_dirs
  local dest_j node_j level_j
  dest_j="$(json_escape "$DEST_SERVER")"
  node_j="$(json_escape "$NODE_NAME")"
  level_j="$(json_escape "$LOG_LEVEL")"

  cat > "$CONFIG_FILE" <<EOF_CONFIG
{
  "log": {
    "loglevel": "${level_j}",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "${node_j}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest_j}:443",
          "xver": 0,
          "serverNames": [
            "${dest_j}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF_CONFIG
  chmod 600 "$CONFIG_FILE"
}

write_client_files() {
  local node_yaml dest_yaml
  node_yaml="$(yaml_escape "$NODE_NAME")"
  dest_yaml="$(yaml_escape "$DEST_SERVER")"

  [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="$(get_public_ip || true)"
  [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="YOUR_SERVER_IP"

  local encoded_name="$NODE_NAME"
  encoded_name="${encoded_name// /%20}"

  local share_link="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${encoded_name}"
  echo "$share_link" > "$SHARE_FILE"
  chmod 600 "$SHARE_FILE"

  cat > "$CLASH_FILE" <<EOF_CLASH
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: :9090

dns:
  enable: true
  ipv6: false
  default-nameserver: [223.5.5.5, 119.29.29.29]
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  use-hosts: true
  nameserver: ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query']
  fallback: ['https://dns.cloudflare.com/dns-query', 'tls://8.8.8.8:853']
  fallback-filter:
    geoip: true
    ipcidr: [240.0.0.0/4, 0.0.0.0/32]

proxies:
  - name: "${node_yaml}"
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${dest_yaml}"
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: chrome

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - "${node_yaml}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
EOF_CLASH
  chmod 600 "$CLASH_FILE"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF_SERVICE
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
pidfile="/run/xray.pid"
command_background="yes"
output_log="${LOG_DIR}/service.out.log"
error_log="${LOG_DIR}/service.err.log"
rc_ulimit="-n 30000"
rc_cgroup_cleanup="yes"

depend() {
  need net
  after net
}
EOF_SERVICE
  chmod +x "$SERVICE_FILE"
  if command -v rc-update >/dev/null 2>&1; then
    rc-update add xray default >/dev/null 2>&1 || true
  fi
}

test_config() {
  if [[ ! -x "$XRAY_BIN" ]]; then
    red "未找到 ${XRAY_BIN}，请先安装/更新 Xray 内核。"
    return 1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    red "未找到 ${CONFIG_FILE}。"
    return 1
  fi
  "$XRAY_BIN" run -test -c "$CONFIG_FILE"
}

restart_xray() {
  write_service
  test_config
  service_cmd restart || service_cmd start || true
  sleep 1
}

save_all_and_restart() {
  write_env
  write_config
  write_client_files
  restart_xray
  green "配置已保存并重启 Xray。"
  yellow "配置文件：${CONFIG_FILE}"
  yellow "分享链接：${SHARE_FILE}"
  yellow "Clash Meta：${CLASH_FILE}"
}

show_config() {
  parse_existing_config
  if ! has_config; then
    red "当前没有检测到已有配置。"
    return 1
  fi

  blue "========== 当前 Xray Reality 配置 =========="
  plain "节点名称       : ${NODE_NAME:-}"
  plain "服务器 IP      : ${SERVER_IP:-未知}"
  plain "监听端口       : ${PORT:-未知}"
  plain "协议/安全      : VLESS + TCP + REALITY"
  plain "Flow           : xtls-rprx-vision"
  plain "回落域名/SNI   : ${DEST_SERVER:-未知}"
  plain "UUID           : ${UUID:-未知}"
  plain "Public Key     : ${PUBLIC_KEY:-未知}"
  plain "Short ID       : ${SHORT_ID:-未知}"
  plain "Private Key    : $(mask_value "${PRIVATE_KEY:-}")"
  plain "日志级别       : ${LOG_LEVEL:-warning}"
  plain "配置文件       : ${CONFIG_FILE}"
  plain "分享链接文件   : ${SHARE_FILE}"
  plain "Clash 文件     : ${CLASH_FILE}"
  plain "日志目录       : ${LOG_DIR}"
  blue "==========================================="

  if [[ -f "$SHARE_FILE" ]]; then
    yellow "完整分享链接如下，截图前注意隐藏："
    cat "$SHARE_FILE"
  fi
}

ask_port() {
  local default_port="${1:-26061}"
  local p
  while true; do
    read -rp "请输入 Reality 端口号 [默认: ${default_port}]: " p
    p="${p:-$default_port}"
    if ! is_valid_port "$p"; then
      red "错误：端口号必须是 1~65535 的数字。"
      continue
    fi
    if ! port_is_available "$p"; then
      red "错误：端口 ${p} 已被占用。"
      continue
    fi
    PORT="$p"
    green "端口 ${PORT} 可用。"
    break
  done
}

ask_domain() {
  local default_domain="${1:-www.microsoft.com}"
  local d
  while true; do
    read -rp "请输入回落域名/SNI [默认: ${default_domain}]: " d
    d="${d:-$default_domain}"
    d="$(normalize_domain "$d")"
    if ! validate_domain "$d"; then
      red "回落域名格式不正确，请不要带 http://、https://、路径或空格。"
      continue
    fi
    DEST_SERVER="$d"
    break
  done
}

ask_loglevel() {
  local default_level="${1:-warning}"
  local lv
  while true; do
    read -rp "请输入日志级别 debug/info/warning/error/none [默认: ${default_level}]: " lv
    lv="${lv:-$default_level}"
    case "$lv" in
      debug|info|warning|error|none) LOG_LEVEL="$lv"; break ;;
      *) red "日志级别只能是 debug、info、warning、error、none。" ;;
    esac
  done
}

install_flow() {
  install_deps
  ensure_dirs
  if [[ ! -x "$XRAY_BIN" ]]; then
    install_or_update_xray
  else
    green "检测到 Xray 已存在：${XRAY_BIN}"
    "$XRAY_BIN" version || true
  fi

  parse_existing_config
  if has_config; then
    yellow "检测到已有配置。"
    show_config || true
    read -rp "是否覆盖并重新生成配置？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return 0
  fi

  local current_ip
  current_ip="$(get_public_ip || true)"
  [[ -z "$current_ip" ]] && current_ip="${SERVER_IP:-YOUR_SERVER_IP}"

  ask_port "${PORT:-26061}"
  ask_domain "${DEST_SERVER:-www.microsoft.com}"
  read -rp "请输入节点名称 [默认: ${NODE_NAME:-32M-Reality}]: " NODE_NAME_INPUT
  NODE_NAME="${NODE_NAME_INPUT:-${NODE_NAME:-32M-Reality}}"
  read -rp "请输入服务器公网 IP [默认: ${current_ip}]: " SERVER_IP_INPUT
  SERVER_IP="${SERVER_IP_INPUT:-$current_ip}"
  ask_loglevel "${LOG_LEVEL:-warning}"

  UUID="$(cat /proc/sys/kernel/random/uuid)"
  generate_keys
  save_all_and_restart
  echo
  show_config || true
}

modify_flow() {
  parse_existing_config
  if ! has_config; then
    red "未检测到已有配置，请先安装。"
    return 1
  fi

  local dirty="false"
  while true; do
    clear 2>/dev/null || true
    show_config || true
    echo
    blue "========== 修改配置 =========="
    echo "1. 修改端口"
    echo "2. 修改回落域名/SNI"
    echo "3. 修改服务器公网 IP"
    echo "4. 修改节点名称"
    echo "5. 修改日志级别"
    echo "6. 重新生成 UUID"
    echo "7. 重新生成 Reality 密钥和 Short ID"
    echo "8. 保存并重启"
    echo "0. 取消返回"
    read -rp "请选择: " choice
    case "$choice" in
      1) ask_port "${PORT:-26061}"; dirty="true"; pause ;;
      2) ask_domain "${DEST_SERVER:-www.microsoft.com}"; dirty="true"; pause ;;
      3)
        local new_ip default_ip
        default_ip="${SERVER_IP:-$(get_public_ip || true)}"
        read -rp "请输入服务器公网 IP [默认: ${default_ip}]: " new_ip
        SERVER_IP="${new_ip:-$default_ip}"
        dirty="true"; pause ;;
      4)
        local nn
        read -rp "请输入节点名称 [默认: ${NODE_NAME:-32M-Reality}]: " nn
        NODE_NAME="${nn:-${NODE_NAME:-32M-Reality}}"
        dirty="true"; pause ;;
      5) ask_loglevel "${LOG_LEVEL:-warning}"; dirty="true"; pause ;;
      6) UUID="$(cat /proc/sys/kernel/random/uuid)"; green "已重新生成 UUID：${UUID}"; dirty="true"; pause ;;
      7) generate_keys; green "已重新生成密钥和 Short ID。"; dirty="true"; pause ;;
      8)
        if [[ "$dirty" == "true" ]]; then
          save_all_and_restart
        else
          yellow "没有修改内容。"
        fi
        pause
        return 0 ;;
      0)
        if [[ "$dirty" == "true" ]]; then
          read -rp "存在未保存修改，确认放弃？[y/N]: " yn
          [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        return 0 ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

delete_flow() {
  parse_existing_config
  if ! has_config; then
    yellow "当前没有可删除的配置。"
    return 0
  fi

  show_config || true
  red "删除后当前分享链接和客户端配置会失效。"
  read -rp "确认删除当前 Xray Reality 配置？请输入 DELETE 确认: " confirm
  [[ "$confirm" == "DELETE" ]] || { yellow "已取消。"; return 0; }

  local backup_dir="${XRAY_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a "$CONFIG_FILE" "$ENV_FILE" "$SHARE_FILE" "$CLASH_FILE" "$SERVICE_FILE" "$backup_dir" 2>/dev/null || true

  service_cmd stop >/dev/null 2>&1 || true
  if command -v rc-update >/dev/null 2>&1; then
    rc-update del xray default >/dev/null 2>&1 || true
  fi

  rm -f "$CONFIG_FILE" "$ENV_FILE" "$SHARE_FILE" "$CLASH_FILE" "$SERVICE_FILE"
  yellow "已删除配置，并停止/移除开机自启。备份目录：${backup_dir}"

  read -rp "是否同时清空日志？[y/N]: " clean_logs
  if [[ "$clean_logs" =~ ^[Yy]$ ]]; then
    : > "$LOG_DIR/access.log" 2>/dev/null || true
    : > "$LOG_DIR/error.log" 2>/dev/null || true
    : > "$LOG_DIR/service.out.log" 2>/dev/null || true
    : > "$LOG_DIR/service.err.log" 2>/dev/null || true
    green "日志已清空。"
  fi

  read -rp "是否同时删除 Xray 二进制文件？一般不建议 [y/N]: " del_bin
  if [[ "$del_bin" =~ ^[Yy]$ ]]; then
    rm -f "$XRAY_BIN"
    green "已删除 ${XRAY_BIN}。"
  fi
}

status_flow() {
  parse_existing_config
  blue "========== Xray 状态检测 =========="
  if [[ -x "$XRAY_BIN" ]]; then
    "$XRAY_BIN" version || true
  else
    red "Xray 二进制不存在：${XRAY_BIN}"
  fi
  echo
  if [[ -f "$CONFIG_FILE" ]]; then
    yellow "配置测试："
    test_config || true
  else
    red "配置文件不存在：${CONFIG_FILE}"
  fi
  echo
  yellow "服务状态："
  service_cmd status || true
  echo
  if command -v ss >/dev/null 2>&1; then
    yellow "监听端口："
    if [[ -n "${PORT:-}" ]]; then
      ss -lntp | grep -E ":${PORT}[[:space:]]" || red "未看到端口 ${PORT} 监听。"
    else
      ss -lntp | grep xray || true
    fi
  fi
  echo
  yellow "最近错误日志："
  tail -n 50 "$LOG_DIR/error.log" "$LOG_DIR/service.err.log" 2>/dev/null || true
}

logs_flow() {
  ensure_dirs
  while true; do
    blue "========== 日志管理 =========="
    echo "1. 查看最近 100 行 access.log"
    echo "2. 查看最近 100 行 error.log"
    echo "3. 查看最近 100 行 service 日志"
    echo "4. 实时跟踪全部日志 tail -f"
    echo "5. 修改日志级别"
    echo "6. 清空日志"
    echo "7. 生成 tcpdump 排查命令"
    echo "0. 返回"
    read -rp "请选择: " choice
    case "$choice" in
      1) tail -n 100 "$LOG_DIR/access.log" 2>/dev/null || true; pause ;;
      2) tail -n 100 "$LOG_DIR/error.log" 2>/dev/null || true; pause ;;
      3) tail -n 100 "$LOG_DIR/service.out.log" "$LOG_DIR/service.err.log" 2>/dev/null || true; pause ;;
      4)
        yellow "按 Ctrl+C 退出实时日志。"
        tail -f "$LOG_DIR/access.log" "$LOG_DIR/error.log" "$LOG_DIR/service.out.log" "$LOG_DIR/service.err.log" ;;
      5)
        parse_existing_config
        ask_loglevel "${LOG_LEVEL:-warning}"
        if has_config; then
          save_all_and_restart
        else
          write_env
          yellow "未检测到 config.json，仅保存日志级别到 ${ENV_FILE}。"
        fi
        pause ;;
      6)
        read -rp "确认清空日志？[y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
          : > "$LOG_DIR/access.log" 2>/dev/null || true
          : > "$LOG_DIR/error.log" 2>/dev/null || true
          : > "$LOG_DIR/service.out.log" 2>/dev/null || true
          : > "$LOG_DIR/service.err.log" 2>/dev/null || true
          green "日志已清空。"
        fi
        pause ;;
      7)
        parse_existing_config
        yellow "如果你要确认客户端流量有没有打到服务器，可以执行："
        echo "apk add --no-cache tcpdump"
        echo "tcpdump -ni any tcp port ${PORT:-你的端口}"
        pause ;;
      0) return 0 ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

menu() {
  need_root
  install_deps
  ensure_dirs
  while true; do
    parse_existing_config
    clear 2>/dev/null || true
    blue "========== Reality Alpine Manager =========="
    if has_config; then
      green "当前状态：已检测到配置  ${SERVER_IP:-未知}:${PORT:-未知}  SNI=${DEST_SERVER:-未知}"
    else
      yellow "当前状态：未检测到配置"
    fi
    echo "1. 显示当前已有配置"
    echo "2. 安装/重新生成配置"
    echo "3. 修改已有配置"
    echo "4. 删除已有配置"
    echo "5. 重启并检测状态"
    echo "6. 日志管理"
    echo "7. 更新/重装 Xray 内核"
    echo "0. 退出"
    read -rp "请选择: " choice
    case "$choice" in
      1) show_config || true; pause ;;
      2) install_flow; pause ;;
      3) modify_flow; pause ;;
      4) delete_flow; pause ;;
      5) restart_xray || true; status_flow; pause ;;
      6) logs_flow ;;
      7) install_or_update_xray; pause ;;
      0) exit 0 ;;
      *) red "无效选择"; pause ;;
    esac
  done
}

case "${1:-menu}" in
  menu) menu ;;
  install) need_root; install_flow ;;
  show) need_root; show_config ;;
  modify) need_root; modify_flow ;;
  delete) need_root; delete_flow ;;
  status) need_root; parse_existing_config; status_flow ;;
  logs) need_root; logs_flow ;;
  update) need_root; install_deps; install_or_update_xray ;;
  restart) need_root; parse_existing_config; restart_xray ;;
  *)
    echo "用法: $0 [menu|install|show|modify|delete|status|logs|update|restart]"
    exit 1
    ;;
esac
