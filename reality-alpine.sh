#!/bin/bash
set -Eeuo pipefail

red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

XRAY_DIR="/root/Xray"
XRAY_BIN="$XRAY_DIR/xray"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        red "缺少依赖：$1"
        yellow "Alpine/OpenRC 可先执行：apk add --no-cache bash curl unzip openrc ca-certificates"
        exit 1
    }
}

need_cmd unzip
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    red "缺少下载工具：wget 或 curl 至少需要一个"
    yellow "Alpine/OpenRC 可先执行：apk add --no-cache wget curl ca-certificates"
    exit 1
fi

get_arch_zip() {
    case "$(uname -m)" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i686) echo "Xray-linux-32.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
        riscv64) echo "Xray-linux-riscv64.zip" ;;
        *)
            red "暂不支持当前架构：$(uname -m)"
            exit 1
            ;;
    esac
}

fetch_to_file() {
    local url="$1"
    local output="$2"

    rm -f "$output"

    # Alpine 默认通常自带 busybox wget，优先用 wget，避免 curl stdout/管道导致的 23 错误。
    if command -v wget >/dev/null 2>&1; then
        if wget -q --tries=3 --timeout=30 -O "$output" "$url"; then
            return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$output" "$url"; then
            return 0
        fi
    fi

    return 1
}

install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        green "xray文件已存在！"
        return 0
    fi

    local xray_zip download_url tmp_zip
    xray_zip=$(get_arch_zip)
    download_url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_zip}"
    tmp_zip="/tmp/${xray_zip}.$$"

    echo "正在下载xray最新稳定版..."
    yellow "当前CPU架构：$(uname -m)，下载文件：$xray_zip"
    yellow "下载地址：$download_url"

    if [[ -e "$XRAY_DIR" && ! -d "$XRAY_DIR" ]]; then
        red "$XRAY_DIR 已存在但不是目录，请先处理该文件。"
        exit 1
    fi

    mkdir -p "$XRAY_DIR"

    if ! fetch_to_file "$download_url" "$tmp_zip"; then
        red "下载失败：$download_url"
        yellow "这版脚本不再访问 GitHub API 获取版本号；如果这里失败，通常是服务器无法访问 GitHub 下载域名。"
        yellow "可以先测试：wget -O /tmp/xray.zip '$download_url'"
        rm -f "$tmp_zip"
        exit 1
    fi

    if [[ ! -s "$tmp_zip" ]]; then
        red "下载失败：文件为空。"
        rm -f "$tmp_zip"
        exit 1
    fi

    if ! unzip -tq "$tmp_zip" >/dev/null; then
        red "下载到的文件不是有效zip，可能被网络拦截、下载不完整，或当前架构对应的包不存在。"
        yellow "临时文件：$tmp_zip"
        exit 1
    fi

    unzip -oq "$tmp_zip" -d "$XRAY_DIR"
    rm -f "$tmp_zip"
    chmod +x "$XRAY_BIN"

    if [[ -x "$XRAY_BIN" ]]; then
        green "下载成功！"
    else
        red "下载失败：解压后未找到 $XRAY_BIN"
        exit 1
    fi
}
is_port_open() {
    local p="$1"
    timeout 1 bash -c "</dev/tcp/127.0.0.1/${p}" >/dev/null 2>&1
}

install_xray

read -p "请输入reality端口号：" port
sign=false
until $sign; do
    if [[ -z "${port:-}" ]]; then
        red "错误：端口号不能为空，请输入小鸡管家给定的可用端口号!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if ! echo "$port" | grep -qE '^[0-9]+$'; then
        red "错误：端口号必须是数字!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        red "错误：端口号必须介于1~65535之间!"
        read -p "请重新输入reality端口号：" port
        continue
    fi
    if is_port_open "$port"; then
        red "错误：$port 已被占用！"
        read -p "请重新输入reality端口号：" port
    else
        green "成功：端口号 $port 可用!"
        sign=true
    fi
done

UUID=$(cat /proc/sys/kernel/random/uuid)
read -rp "请输入回落域名[默认: www.microsoft.com]: " dest_server
[[ -z "${dest_server:-}" ]] && dest_server="www.microsoft.com"
short_id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
keys=$("$XRAY_BIN" x25519)
private_key=$(echo "$keys" | awk '/Private key:/ {print $3}')
public_key=$(echo "$keys" | awk '/Public key:/ {print $3}')

green "private_key: $private_key"
green "public_key: $public_key"
green "short_id: $short_id"

cat > "$XRAY_DIR/config.json" << EOF_JSON
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "$dest_server:443",
          "xver": 0,
          "serverNames": [
            "$dest_server"
          ],
          "privateKey": "$private_key",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "$short_id"
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
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": false,
        "statsUserDownlink": false,
        "bufferSize": 1024
      }
    }
  }
}
EOF_JSON

IP=""
ip_tmp="/tmp/xray_public_ip.$$"
if fetch_to_file "https://api.ip.sb/ip" "$ip_tmp"; then
    IP=$(tr -d '[:space:]' < "$ip_tmp")
fi
if [[ -z "${IP:-}" ]] && fetch_to_file "https://api.ipify.org" "$ip_tmp"; then
    IP=$(tr -d '[:space:]' < "$ip_tmp")
fi
rm -f "$ip_tmp"
if [[ -z "${IP:-}" ]]; then
    yellow "自动获取公网IP失败。"
    read -rp "请手动输入服务器公网IP：" IP
fi
green "您的IP为：$IP"

share_link="vless://$UUID@$IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#32M-Reality"
echo "$share_link" > "$XRAY_DIR/share-link.txt"

cat > "$XRAY_DIR/clash-meta.yaml" << EOF_YAML
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
    fallback: ['https://doh.dns.sb/dns-query', 'https://dns.cloudflare.com/dns-query', 'https://dns.twnic.tw/dns-query', 'tls://8.8.4.4:853']
    fallback-filter: { geoip: true, ipcidr: [240.0.0.0/4, 0.0.0.0/32] }

proxies:
  - name: 32M-Reality
    type: vless
    server: $IP
    port: $port
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    xudp: true
    flow: xtls-rprx-vision
    servername: $dest_server
    reality-opts:
      public-key: "$public_key"
      short-id: "$short_id"
    client-fingerprint: chrome

proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - 32M-Reality
      - DIRECT

rules:
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,🚀 节点选择
EOF_YAML

yellow "Clash Meta配置文件已保存到：$XRAY_DIR/clash-meta.yaml"
yellow "reality的分享链接已保存到：$XRAY_DIR/share-link.txt"
echo
green "reality的分享链接为："
red "$share_link"

cat > /etc/init.d/xray << 'EOF_INIT'
#!/sbin/openrc-run
name="xray"
description="Xray Service"

command="/root/Xray/xray"
command_args="run -config /root/Xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"
rc_ulimit="-n 30000"
rc_cgroup_cleanup="yes"

depend() {
    need net
    after net
}

stop() {
   ebegin "Stopping xray"
   start-stop-daemon --stop --name xray
   eend $?
}
EOF_INIT

chmod u+x /etc/init.d/xray
if command -v rc-update >/dev/null 2>&1; then
    if ! rc-update show | grep xray | grep 'default' >/dev/null; then
        rc-update add xray default
    fi
fi

if command -v service >/dev/null 2>&1; then
    service xray restart
    service xray status
else
    yellow "未找到service命令，请手动启动：/root/Xray/xray run -config /root/Xray/config.json"
fi

cd /root
