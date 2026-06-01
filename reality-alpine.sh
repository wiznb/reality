#!/usr/bin/env bash
set -Eeuo pipefail

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

if [[ "$(id -u)" != "0" ]]; then
  red "请使用 root 用户执行本脚本"
  exit 1
fi

if command -v apk >/dev/null 2>&1; then
  yellow "正在安装/检查依赖..."
  apk add --no-cache bash wget unzip openrc ca-certificates curl coreutils iproute2 >/dev/null || true
  update-ca-certificates >/dev/null 2>&1 || true
fi

mkdir -p /root/Xray
cd /root

arch_raw="$(uname -m)"
case "$arch_raw" in
  x86_64|amd64) xray_arch="64" ;;
  i386|i686) xray_arch="32" ;;
  aarch64|arm64) xray_arch="arm64-v8a" ;;
  armv7l|armv7*) xray_arch="arm32-v7a" ;;
  armv6l|armv6*) xray_arch="arm32-v6" ;;
  *) red "暂不支持的CPU架构：$arch_raw"; exit 1 ;;
esac

zip_name="Xray-linux-${xray_arch}.zip"
download_url="https://github.com/XTLS/Xray-core/releases/latest/download/${zip_name}"
yellow "当前CPU架构：${arch_raw}，下载文件：${zip_name}"
yellow "下载地址：${download_url}"

rm -f "/tmp/${zip_name}"
if ! wget --no-check-certificate -O "/tmp/${zip_name}" "$download_url"; then
  red "下载失败，请检查服务器是否能访问 github.com"
  exit 1
fi

unzip -o "/tmp/${zip_name}" -d /root/Xray >/dev/null
rm -f "/tmp/${zip_name}"
chmod +x /root/Xray/xray

green "下载成功！"
/root/Xray/xray version || true

read -rp "请输入reality端口号：" port
while true; do
  if [[ -z "${port}" ]]; then
    red "错误：端口号不能为空，请输入可用端口号!"
  elif ! [[ "$port" =~ ^[0-9]+$ ]]; then
    red "错误：端口号必须是数字!"
  elif (( port < 1 || port > 65535 )); then
    red "错误：端口号必须介于1~65535之间!"
  elif command -v ss >/dev/null 2>&1 && ss -lnt | awk '{print $4}' | grep -qE "(^|:)${port}$"; then
    red "错误：$port 已被占用！"
  else
    green "成功：端口号 $port 可用!"
    break
  fi
  read -rp "请重新输入reality端口号：" port
done

UUID="$(cat /proc/sys/kernel/random/uuid)"
read -rp "请输入回落域名[默认: www.microsoft.com]: " dest_server
[[ -z "$dest_server" ]] && dest_server="www.microsoft.com"

short_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

key_output="$(/root/Xray/xray x25519 2>&1 || true)"
yellow "x25519原始输出："
echo "$key_output"

private_key="$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /private[[:space:]]*key/ {print $2; exit}')"
public_key="$(printf '%s\n' "$key_output" | awk -F':[[:space:]]*' 'tolower($1) ~ /public[[:space:]]*key/ {print $2; exit}')"

if [[ -z "$private_key" || -z "$public_key" ]]; then
  red "生成 REALITY 密钥失败：private_key 或 public_key 为空。"
  red "请把上面的 x25519 原始输出截图发我。"
  exit 1
fi

green "private_key: $private_key"
green "public_key: $public_key"
green "short_id: $short_id"

cat > /root/Xray/config.json <<EOF_CONFIG
{
  "log": {
    "loglevel": "warning",
    "access": "/root/Xray/access.log",
    "error": "/root/Xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest_server}:443",
          "xver": 0,
          "serverNames": [
            "${dest_server}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
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
  ]
}
EOF_CONFIG

if ! /root/Xray/xray run -test -c /root/Xray/config.json; then
  red "Xray 配置测试失败，请查看 /root/Xray/config.json"
  exit 1
fi

IP="$(wget -qO- --no-check-certificate -U Mozilla https://api.ip.sb/ip || true)"
if [[ -z "$IP" ]]; then
  IP="$(wget -qO- --no-check-certificate -U Mozilla https://ifconfig.me || true)"
fi
if [[ -z "$IP" ]]; then
  red "无法获取公网IP，请手动查看服务器公网IP。"
  IP="YOUR_SERVER_IP"
fi

green "您的IP为：$IP"

share_link="vless://${UUID}@${IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#32M-Reality"
echo "$share_link" > /root/Xray/share-link.txt

cat > /root/Xray/clash-meta.yaml <<EOF_CLASH
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: :9090
proxies:
  - name: 32M-Reality
    type: vless
    server: ${IP}
    port: ${port}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${dest_server}
    reality-opts:
      public-key: "${public_key}"
      short-id: "${short_id}"
    client-fingerprint: chrome
proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 32M-Reality
      - DIRECT
rules:
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,节点选择
EOF_CLASH

yellow "Clash Meta配置文件已保存到：/root/Xray/clash-meta.yaml"
yellow "reality的分享链接已保存到：/root/Xray/share-link.txt"

echo
cat > /etc/init.d/xray <<'EOF_SERVICE'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/root/Xray/xray"
command_args="run -c /root/Xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"
output_log="/root/Xray/xray.out.log"
error_log="/root/Xray/xray.err.log"
rc_ulimit="-n 30000"
rc_cgroup_cleanup="yes"

depend() {
  need net
  after net
}
EOF_SERVICE

chmod +x /etc/init.d/xray
rc-update add xray default >/dev/null 2>&1 || true
service xray restart
sleep 1
service xray status || true

if command -v ss >/dev/null 2>&1; then
  ss -lntp | grep -E ":${port}[[:space:]]" || true
fi

green "reality的分享链接为："
red "$share_link"
