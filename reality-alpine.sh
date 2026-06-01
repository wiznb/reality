#!/usr/bin/env bash
[ -z "${BASH_VERSION:-}" ] && { echo "请使用 bash 运行：bash $0"; exit 1; }

# REALITY 一键安装脚本 - 支持 Debian/Ubuntu/CentOS/Alpine

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

NAME="xray"
CONFIG_DIR="/usr/local/etc/${NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SHARE_DIR="/usr/local/share/${NAME}"
LOG_DIR="/var/log/${NAME}"
SERVICE_FILE="/etc/systemd/system/${NAME}.service"
INIT_SYSTEM=""
PMT=""
IS_ALPINE=0

colorEcho() {
    echo -e "${1}${*:2}${PLAIN}"
}

ensure_xray_dir() {
    mkdir -p "$CONFIG_DIR" "$SHARE_DIR" "$LOG_DIR"
}

detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
        SERVICE_FILE="/etc/systemd/system/${NAME}.service"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
        SERVICE_FILE="/etc/init.d/${NAME}"
    else
        INIT_SYSTEM="unknown"
    fi
}

checkSystem() {
    if [[ "$(id -u)" != "0" ]]; then
        colorEcho "$RED" " 请以 root 身份执行该脚本"
        exit 1
    fi

    if command -v apk >/dev/null 2>&1; then
        PMT="apk"
        IS_ALPINE=1
        CMD_INSTALL="apk add --no-cache"
        CMD_REMOVE="apk del"
        CMD_UPGRADE="apk update; apk upgrade"
    elif command -v apt >/dev/null 2>&1; then
        PMT="apt"
        IS_ALPINE=0
        CMD_INSTALL="apt install -y"
        CMD_REMOVE="apt remove -y"
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
    elif command -v yum >/dev/null 2>&1; then
        PMT="yum"
        IS_ALPINE=0
        CMD_INSTALL="yum install -y"
        CMD_REMOVE="yum remove -y"
        CMD_UPGRADE="yum update -y"
    else
        colorEcho "$RED" " 不受支持的 Linux 系统：仅支持 apt / yum / apk"
        exit 1
    fi

    detect_init_system
    if [[ "$INIT_SYSTEM" == "unknown" ]]; then
        colorEcho "$RED" " 未检测到 systemd 或 OpenRC，无法管理 xray 服务"
        exit 1
    fi
}

preinstall() {
    echo ""
    echo "安装必要软件，请等待..."

    case "$PMT" in
        apk)
            apk update >/dev/null 2>&1 || true
            $CMD_INSTALL bash curl openssl qrencode jq unzip ca-certificates iproute2 coreutils >/dev/null 2>&1
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
        apt)
            apt update >/dev/null 2>&1 || true
            $CMD_INSTALL curl openssl qrencode jq unzip ca-certificates iproute2 coreutils >/dev/null 2>&1
            if ! command -v ufw >/dev/null 2>&1; then
                $CMD_INSTALL ufw >/dev/null 2>&1 || true
            fi
            ;;
        yum)
            yum clean all >/dev/null 2>&1 || true
            $CMD_INSTALL curl openssl qrencode jq unzip ca-certificates iproute coreutils >/dev/null 2>&1
            ;;
    esac

    if [[ -s /etc/selinux/config ]] && grep 'SELINUX=enforcing' /etc/selinux/config >/dev/null 2>&1; then
        sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
        setenforce 0 >/dev/null 2>&1 || true
    fi
}

service_daemon_reload() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

service_enable() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl enable "$NAME" >/dev/null 2>&1 || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add "$NAME" default >/dev/null 2>&1 || true
    fi
}

service_start() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl start "$NAME"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$NAME" start
    else
        return 1
    fi
}

service_restart() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart "$NAME"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$NAME" restart
    else
        return 1
    fi
}

service_stop() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "$NAME"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$NAME" stop
    else
        return 1
    fi
}

service_status_detail() {
    detect_init_system
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl status "$NAME" --no-pager -l
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$NAME" status
    fi
}

create_systemd_service() {
    cat > /etc/systemd/system/${NAME}.service <<EOF_SYSTEMD
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
}

create_openrc_service() {
    cat > /etc/init.d/${NAME} <<'EOF_OPENRC'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

start_pre() {
    checkpath -d -m 0755 /usr/local/etc/xray
    checkpath -d -m 0755 /usr/local/share/xray
    checkpath -d -m 0755 /var/log/xray
}

depend() {
    need net
    after firewall
}
EOF_OPENRC
    chmod +x /etc/init.d/${NAME}
}

random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i1025-65000 -n1
    else
        awk 'BEGIN{srand(); print int(1025+rand()*(65000-1025))}'
    fi
}

random_website() {
    local domains=(
        "one-piece.com"
        "www.lovelive-anime.jp"
        "www.swift.com"
        "academy.nvidia.com"
        "www.cisco.com"
        "www.samsung.com"
        "www.amd.com"
        "www.apple.com"
        "music.apple.com"
        "www.amazon.com"
        "www.fandom.com"
        "tidal.com"
        "zoro.to"
        "www.pixiv.co.jp"
        "mxj.myanimelist.net"
        "mora.jp"
        "www.j-wave.co.jp"
        "www.dmm.com"
        "booth.pm"
        "www.ivi.tv"
        "www.leercapitulo.com"
        "www.sky.com"
        "itunes.apple.com"
        "download-installer.cdn.mozilla.net"
    )
    local total_domains=${#domains[@]}
    local random_index=$((RANDOM % total_domains))
    echo "${domains[random_index]}"
}

check_tls_site() {
    local domain="$1"
    local output=""

    if command -v timeout >/dev/null 2>&1; then
        output=$(echo QUIT | timeout 8 openssl s_client -connect "${domain}:443" -servername "${domain}" -tls1_3 -alpn h2 2>&1)
    else
        output=$(echo QUIT | openssl s_client -connect "${domain}:443" -servername "${domain}" -tls1_3 -alpn h2 2>&1)
    fi

    echo "$output" | grep -Eoi '(TLSv1.3)|(^ALPN[[:space:]]+protocol:[[:space:]]+h2$)|(X25519)' | sort -u | wc -l
}

xray_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "Xray-linux-64.zip"
            ;;
        aarch64|arm64)
            echo "Xray-linux-arm64-v8a.zip"
            ;;
        armv7l|armv7*)
            echo "Xray-linux-arm32-v7a.zip"
            ;;
        armv6l|armv6*)
            echo "Xray-linux-arm32-v6.zip"
            ;;
        i386|i686)
            echo "Xray-linux-32.zip"
            ;;
        *)
            return 1
            ;;
    esac
}

installXrayDirect() {
    local asset tmpdir url

    asset=$(xray_asset_name) || {
        colorEcho "$RED" " 不支持的 CPU 架构：$(uname -m)"
        exit 1
    }

    tmpdir=$(mktemp -d)
    url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"

    echo "正在从 GitHub 下载 ${asset}..."
    if ! curl -fL "$url" -o "${tmpdir}/xray.zip"; then
        rm -rf "$tmpdir"
        colorEcho "$RED" " xray 下载失败，请检查网络或 GitHub 连通性"
        exit 1
    fi

    if ! unzip -oq "${tmpdir}/xray.zip" -d "$tmpdir"; then
        rm -rf "$tmpdir"
        colorEcho "$RED" " xray 解压失败"
        exit 1
    fi

    ensure_xray_dir
    install -m 755 "${tmpdir}/xray" /usr/local/bin/xray
    [[ -f "${tmpdir}/geoip.dat" ]] && install -m 644 "${tmpdir}/geoip.dat" "${SHARE_DIR}/geoip.dat"
    [[ -f "${tmpdir}/geosite.dat" ]] && install -m 644 "${tmpdir}/geosite.dat" "${SHARE_DIR}/geosite.dat"
    rm -rf "$tmpdir"

    detect_init_system
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        create_openrc_service
    elif [[ "$INIT_SYSTEM" == "systemd" ]]; then
        create_systemd_service
        service_daemon_reload
    fi
    service_enable
}

installXray() {
    echo ""
    echo "正在安装 Xray..."

    if [[ "$PMT" == "apk" || "$IS_ALPINE" == "1" ]]; then
        installXrayDirect
    else
        bash -c "$(curl -s -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" >/dev/null 2>&1
        detect_init_system
        [[ "$INIT_SYSTEM" == "systemd" && ! -f "$SERVICE_FILE" ]] && create_systemd_service
        service_enable
    fi

    colorEcho "$BLUE" "xray 内核已安装完成"
    sleep 2
}

updateXray() {
    echo ""
    echo "正在更新 Xray..."

    if [[ "$PMT" == "apk" || "$IS_ALPINE" == "1" ]]; then
        installXrayDirect
    else
        bash -c "$(curl -s -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" >/dev/null 2>&1
        detect_init_system
        [[ "$INIT_SYSTEM" == "systemd" && ! -f "$SERVICE_FILE" ]] && create_systemd_service
        service_enable
    fi

    colorEcho "$BLUE" "xray 内核已更新完成"
    sleep 2
}

removeXray() {
    echo ""
    echo "正在卸载 Xray..."
    detect_init_system
    service_stop >/dev/null 2>&1 || true

    if [[ "$PMT" != "apk" && "$IS_ALPINE" != "1" ]]; then
        bash -c "$(curl -s -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl disable "$NAME" >/dev/null 2>&1 || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update del "$NAME" default >/dev/null 2>&1 || true
    fi

    rm -f /etc/systemd/system/xray.service >/dev/null 2>&1
    rm -f /etc/systemd/system/xray@.service >/dev/null 2>&1
    rm -f /etc/init.d/xray >/dev/null 2>&1
    rm -f /usr/local/bin/xray >/dev/null 2>&1
    rm -rf "$CONFIG_DIR" "$SHARE_DIR" "$LOG_DIR" >/dev/null 2>&1
    service_daemon_reload

    colorEcho "$RED" "已完成 xray 卸载"
    sleep 2
}

status() {
    export PATH=/usr/local/bin:$PATH

    if ! command -v xray >/dev/null 2>&1; then
        echo 0
        return
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo 1
        return
    fi

    local port res
    port=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | awk '{print $2}')
    if [[ -z "$port" ]]; then
        echo 2
        return
    fi

    if command -v ss >/dev/null 2>&1; then
        res=$(ss -ntlp 2>/dev/null | grep ":${port}" | grep xray || true)
        if [[ -n "$res" ]]; then
            echo 3
            return
        fi
    fi

    if command -v pgrep >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1; then
        echo 3
    else
        echo 2
    fi
}

statusText() {
    local res
    res=$(status)
    case $res in
        2)
            echo -e "${GREEN}已安装xray${PLAIN} ${RED}未运行${PLAIN}"
            ;;
        3)
            echo -e "${GREEN}已安装xray${PLAIN} ${GREEN}正在运行${PLAIN}"
            ;;
        *)
            echo -e "${RED}未安装xray${PLAIN}"
            ;;
    esac
}

getuuid() {
    ensure_xray_dir
    echo ""
    echo "正在生成 UUID..."
    /usr/local/bin/xray uuid > "${CONFIG_DIR}/uuid"
    USER_UUID=$(cat "${CONFIG_DIR}/uuid")
    colorEcho "$BLUE" "UUID：$USER_UUID"
    echo ""
}

getname() {
    ensure_xray_dir
    read -p "请输入您的节点名称，如果留空将保持默认：" USER_NAME
    [[ -z "$USER_NAME" ]] && USER_NAME="Reality(by wiznb)"
    colorEcho "$BLUE" "节点名称：$USER_NAME"
    echo "$USER_NAME" > "${CONFIG_DIR}/name"
    echo ""
}

parse_x25519_keys() {
    local key_file="$1"
    local private_key public_key

    private_key=$(awk -F': ' '
        /^PrivateKey:/ {print $2}
        /^Private key:/ {print $2}
    ' "$key_file" | head -n1 | tr -d '\r')

    public_key=$(awk -F': ' '
        /^PublicKey:/ {print $2}
        /^Public key:/ {print $2}
        /^Password \(PublicKey\):/ {print $2}
    ' "$key_file" | head -n1 | tr -d '\r')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        return 1
    fi

    echo "$private_key|$public_key"
    return 0
}

getkey() {
    ensure_xray_dir
    echo "正在生成 Reality 私钥和公钥..."
    /usr/local/bin/xray x25519 > "${CONFIG_DIR}/key"

    key_pair=$(parse_x25519_keys "${CONFIG_DIR}/key")
    if [[ $? -ne 0 || -z "$key_pair" ]]; then
        colorEcho "$RED" "密钥生成失败，xray 输出如下："
        cat "${CONFIG_DIR}/key"
        exit 1
    fi

    private_key="${key_pair%%|*}"
    public_key="${key_pair##*|}"

    echo -n "$private_key" > "${CONFIG_DIR}/privatekey"
    echo -n "$public_key" > "${CONFIG_DIR}/publickey"

    colorEcho "$BLUE" "PrivateKey: $private_key"
    colorEcho "$BLUE" "PublicKey : $public_key"
    echo ""
}

choose_ip() {
    local LOCAL_IPv4 LOCAL_IPv6 USER_IP
    LOCAL_IPv4=$(curl -s -4 https://api.ipify.org || true)
    LOCAL_IPv6=$(curl -s -6 https://api64.ipify.org || true)

    if [[ -n "$LOCAL_IPv4" && "$LOCAL_IPv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ -n "$LOCAL_IPv6" && "$LOCAL_IPv6" =~ ^[0-9a-fA-F:]+$ ]]; then
            colorEcho "$YELLOW" "本机 IPv4 地址：$LOCAL_IPv4"
            colorEcho "$YELLOW" "本机 IPv6 地址：$LOCAL_IPv6"
            read -p "请确定你的节点 IP，默认 IPv4（0：IPv4；1：IPv6）:" USER_IP
            if [[ "$USER_IP" == "1" ]]; then
                LOCAL_IP=$LOCAL_IPv6
            else
                LOCAL_IP=$LOCAL_IPv4
            fi
        else
            colorEcho "$YELLOW" "本机仅有 IPv4 地址：$LOCAL_IPv4"
            LOCAL_IP=$LOCAL_IPv4
        fi
    elif [[ -n "$LOCAL_IPv6" && "$LOCAL_IPv6" =~ ^[0-9a-fA-F:]+$ ]]; then
        colorEcho "$YELLOW" "本机仅有 IPv6 地址：$LOCAL_IPv6"
        LOCAL_IP=$LOCAL_IPv6
    else
        colorEcho "$RED" "未能获取到有效的公网 IP 地址。"
        exit 1
    fi

    colorEcho "$BLUE" "节点 IP：$LOCAL_IP"
    echo "$LOCAL_IP" > "${CONFIG_DIR}/ip"
}

getip() {
    ensure_xray_dir
    choose_ip
}

prompt_port() {
    local PORT
    while true; do
        read -p "请设置 XRAY 的端口号[1025-65535]，不输入则随机生成:" PORT
        [[ -z "$PORT" ]] && PORT=$(random_port)

        if [[ "${PORT:0:1}" = "0" ]]; then
            colorEcho "$RED" "端口不能以 0 开头"
            continue
        fi

        if [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1025 ]] && [[ "$PORT" -le 65535 ]]; then
            echo "$PORT" > "${CONFIG_DIR}/port"
            colorEcho "$BLUE" "端口号：$PORT"
            break
        else
            colorEcho "$RED" "输入错误，端口号为 1025-65535 的数字"
        fi
    done
}

getport() {
    ensure_xray_dir
    echo ""
    prompt_port
}

setFirewall() {
    local PORT
    PORT=$(cat "${CONFIG_DIR}/port")
    echo ""
    echo "正在开启 $PORT 端口..."

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${PORT}/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        colorEcho "$YELLOW" "$PORT 端口已成功开启"
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
        ufw allow ${PORT}/udp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
        colorEcho "$YELLOW" "$PORT 端口已成功开启"
    else
        colorEcho "$YELLOW" "无法自动配置防火墙规则，请手动放行端口：$PORT"
        if [[ "$PMT" == "apk" ]]; then
            colorEcho "$YELLOW" "Alpine 默认可能没有启用防火墙；如启用了 nftables/iptables，请手动放行 TCP/UDP ${PORT}。"
        fi
    fi
}

select_dest() {
    local USER_DEST domain check_num
    read -p "请输入您的 dest 地址并确保该域名在国内的连通性（例如：www.amazon.com），如果留空将随机生成：" USER_DEST

    if [[ -n "$USER_DEST" ]]; then
        echo "正在检查 \"${USER_DEST}\" 是否支持 TLSv1.3 与 h2"
        check_num=$(check_tls_site "$USER_DEST")
        if [[ "$check_num" -eq 3 ]]; then
            echo "${USER_DEST}:443" > "${CONFIG_DIR}/dest"
            echo "$USER_DEST" > "${CONFIG_DIR}/servername"
            colorEcho "$YELLOW" "目标网址：\"${USER_DEST}\" 支持 TLSv1.3 与 h2"
            return
        fi
        colorEcho "$YELLOW" "目标网址：\"${USER_DEST}\" 不支持 TLSv1.3 与 h2，将在默认域名组中随机挑选域名"
    fi

    while true; do
        domain=$(random_website)
        check_num=$(check_tls_site "$domain")
        if [[ "$check_num" -eq 3 ]]; then
            USER_DEST="$domain"
            break
        fi
    done

    echo "${USER_DEST}:443" > "${CONFIG_DIR}/dest"
    echo "$USER_DEST" > "${CONFIG_DIR}/servername"
    colorEcho "$BLUE" "选中的符合条件的网站是：$USER_DEST"
}

getdest() {
    ensure_xray_dir
    echo ""
    select_dest
}

getsid() {
    ensure_xray_dir
    echo ""
    echo "正在生成 shortID..."
    USER_SID=$(openssl rand -hex 8)
    echo "$USER_SID" > "${CONFIG_DIR}/sid"
    colorEcho "$BLUE" "shortID：$USER_SID"
    echo ""
}

generate_config() {
    ensure_xray_dir

    cat > "$CONFIG_FILE" <<EOF_CONFIG
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": $(cat "${CONFIG_DIR}/port"),
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$(cat "${CONFIG_DIR}/uuid")",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$(cat "${CONFIG_DIR}/dest")",
                    "serverNames": [
                        "$(cat "${CONFIG_DIR}/servername")"
                    ],
                    "privateKey": "$(cat "${CONFIG_DIR}/privatekey")",
                    "shortIds": [
                        "",
                        "$(cat "${CONFIG_DIR}/sid")"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF_CONFIG

    echo "创建配置文件完成..."
    echo ""
}

print_config() {
    echo ""
    colorEcho "$BLUE" "reality 节点配置信息如下："
    colorEcho "$YELLOW" "Server IP: ${PLAIN}$(cat "${CONFIG_DIR}/ip")"
    colorEcho "$YELLOW" "Listen Port: ${PLAIN}$(cat "${CONFIG_DIR}/port")"
    colorEcho "$YELLOW" "Server Name: ${PLAIN}$(cat "${CONFIG_DIR}/servername")"
    colorEcho "$YELLOW" "Public Key: ${PLAIN}$(cat "${CONFIG_DIR}/publickey")"
    colorEcho "$YELLOW" "Short ID: ${PLAIN}$(cat "${CONFIG_DIR}/sid")"
    colorEcho "$YELLOW" "UUID: ${PLAIN}$(cat "${CONFIG_DIR}/uuid")"
    echo ""
}

generate_link() {
    local required_files=(ip port uuid servername publickey sid name)
    local file LOCAL_IP LINK

    for file in "${required_files[@]}"; do
        if [[ ! -f "${CONFIG_DIR}/${file}" ]]; then
            colorEcho "$RED" "配置不完整，请先完成搭建"
            return 1
        fi
    done

    LOCAL_IP=$(cat "${CONFIG_DIR}/ip")

    if [[ "$LOCAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LINK="vless://$(cat "${CONFIG_DIR}/uuid")@$(cat "${CONFIG_DIR}/ip"):$(cat "${CONFIG_DIR}/port")?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat "${CONFIG_DIR}/servername")&fp=chrome&pbk=$(cat "${CONFIG_DIR}/publickey")&sid=$(cat "${CONFIG_DIR}/sid")&type=tcp&headerType=none#$(cat "${CONFIG_DIR}/name")"
    elif [[ "$LOCAL_IP" =~ ^[0-9a-fA-F:]+$ ]]; then
        LINK="vless://$(cat "${CONFIG_DIR}/uuid")@[$(cat "${CONFIG_DIR}/ip")]:$(cat "${CONFIG_DIR}/port")?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(cat "${CONFIG_DIR}/servername")&fp=chrome&pbk=$(cat "${CONFIG_DIR}/publickey")&sid=$(cat "${CONFIG_DIR}/sid")&type=tcp&headerType=none#$(cat "${CONFIG_DIR}/name")"
    else
        colorEcho "$RED" "没有获取到有效 IP！"
        return 1
    fi

    colorEcho "$BLUE" "reality 订阅链接：${LINK}"
    echo ""
    colorEcho "$YELLOW" "reality 节点二维码（可直接扫码导入到 v2rayN、Shadowrocket 等客户端）："
    qrencode -o - -t utf8 -s 1 "${LINK}"
    echo ""
}

Modify_xrayconfig() {
    local CHOICE key_pair private_key public_key USER_NAME PORT USER_DEST_CHOICE USER_SID
    ensure_xray_dir

    echo ""
    read -p "是否需要更换 UUID（0：保持不变；1：重新生成）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        echo "正在重新生成 UUID..."
        /usr/local/bin/xray uuid > "${CONFIG_DIR}/uuid"
        colorEcho "$BLUE" "UUID：$(cat "${CONFIG_DIR}/uuid")"
    else
        colorEcho "$BLUE" "UUID 保持不变!"
    fi

    echo ""
    read -p "是否需要给节点重命名（0：保持不变；1：重新命名）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        read -p "请输入您的节点名称，如果留空将保持默认：" USER_NAME
        [[ -z "$USER_NAME" ]] && USER_NAME="Reality(by wiznb)"
        echo "$USER_NAME" > "${CONFIG_DIR}/name"
        colorEcho "$BLUE" "节点名称：$USER_NAME"
    else
        colorEcho "$BLUE" "节点名称保持不变!"
    fi

    echo ""
    read -p "是否需要重新生成密钥（0：保持不变；1：重新生成）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        echo "正在生成私钥和公钥，请妥善保管好..."
        /usr/local/bin/xray x25519 > "${CONFIG_DIR}/key"
        key_pair=$(parse_x25519_keys "${CONFIG_DIR}/key")
        if [[ $? -ne 0 || -z "$key_pair" ]]; then
            colorEcho "$RED" "密钥生成失败，xray 输出如下："
            cat "${CONFIG_DIR}/key"
            exit 1
        fi
        private_key="${key_pair%%|*}"
        public_key="${key_pair##*|}"
        echo -n "$private_key" > "${CONFIG_DIR}/privatekey"
        echo -n "$public_key" > "${CONFIG_DIR}/publickey"
        colorEcho "$BLUE" "PrivateKey: $private_key"
        colorEcho "$BLUE" "PublicKey : $public_key"
    else
        colorEcho "$BLUE" "密钥保持不变!"
    fi

    echo ""
    read -p "是否需要更换节点 IP（0：保持不变；1：重新选择）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        choose_ip
    else
        colorEcho "$BLUE" "节点 IP 保持不变!"
    fi

    echo ""
    read -p "是否需要更换端口（0：保持不变；1：更换端口）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        prompt_port
        setFirewall
    else
        colorEcho "$BLUE" "端口保持不变!"
    fi

    echo ""
    read -p "是否需要更换目标网站（0：保持不变；1：重新输入）:" USER_DEST_CHOICE
    if [[ "$USER_DEST_CHOICE" == "1" ]]; then
        select_dest
    else
        colorEcho "$BLUE" "目标网址保持不变!"
    fi

    echo ""
    read -p "是否需要重新生成 shortID（0：保持不变；1：重新生成）:" CHOICE
    if [[ "$CHOICE" == "1" ]]; then
        USER_SID=$(openssl rand -hex 8)
        echo "$USER_SID" > "${CONFIG_DIR}/sid"
        colorEcho "$BLUE" "shortID：$USER_SID"
    else
        colorEcho "$BLUE" "shortID 保持不变!"
    fi
}

start() {
    local res port
    res=$(status)
    if [[ "$res" -lt 2 ]]; then
        colorEcho "$RED" "xray 未安装，请先安装！"
        return
    fi

    service_daemon_reload
    service_start
    sleep 2

    port=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | awk '{print $2}')
    if command -v ss >/dev/null 2>&1; then
        res=$(ss -ntlp 2>/dev/null | grep ":${port}" | grep xray || true)
    else
        res=$(pgrep -x xray 2>/dev/null || true)
    fi

    if [[ -z "$res" ]]; then
        colorEcho "$RED" "xray 启动失败，请检查配置和端口是否被占用！"
        service_status_detail
    else
        colorEcho "$BLUE" "xray 启动成功！"
    fi
}

restart() {
    local res
    res=$(status)
    if [[ "$res" -lt 2 ]]; then
        colorEcho "$RED" "xray 未安装，请先安装！"
        return
    fi

    service_daemon_reload
    service_restart
    sleep 2

    res=$(status)
    if [[ "$res" == "3" ]]; then
        colorEcho "$BLUE" "xray 重启成功！"
    else
        colorEcho "$RED" "xray 重启失败，请检查配置和端口是否被占用！"
        service_status_detail
    fi
}

stop() {
    local res
    res=$(status)
    if [[ "$res" -lt 2 ]]; then
        colorEcho "$RED" "xray 未安装，请先安装！"
        return
    fi

    service_stop
    colorEcho "$BLUE" "xray 停止成功"
}

menu() {
    clear
    colorEcho "$YELLOW" "当前是独立版 Reality 脚本，没有上一级菜单。"
    Xray
}

Xray() {
    clear
    echo "##################################################################"
    echo -e "#                   ${RED}Reality一键安装脚本${PLAIN}                                    #"
    echo -e "# ${GREEN}说明${PLAIN}: 已适配 Alpine / OpenRC，同时兼容 apt / yum / systemd                  #"
    echo "##################################################################"

    echo -e "  ${GREEN}1.${PLAIN}  安装 xray"
    echo -e "  ${GREEN}2.${PLAIN}  更新 xray"
    echo -e "  ${GREEN}3.${RED}  卸载 xray${PLAIN}"
    echo " -------------"
    echo -e "  ${GREEN}4.${PLAIN}  搭建 VLESS-Vision-uTLS-REALITY（xray）"
    echo -e "  ${GREEN}5.${PLAIN}  查看 reality 链接"
    echo -e "  ${GREEN}6.${PLAIN}  修改 reality 配置"
    echo " -------------"
    echo -e "  ${GREEN}7.${PLAIN}  启动 xray"
    echo -e "  ${GREEN}8.${PLAIN}  重启 xray"
    echo -e "  ${GREEN}9.${PLAIN}  停止 xray"
    echo " -------------"
    echo -e "  ${GREEN}10.${PLAIN}  返回上一级菜单"
    echo -e "  ${GREEN}0.${PLAIN}  退出"
    echo -n " 当前 xray 状态："
    statusText
    echo

    read -p " 请选择操作[0-10]：" answer
    case "$answer" in
        0)
            exit 0
            ;;
        1)
            checkSystem
            preinstall
            installXray
            Xray
            ;;
        2)
            checkSystem
            preinstall
            updateXray
            Xray
            ;;
        3)
            checkSystem
            removeXray
            ;;
        4)
            checkSystem
            preinstall
            if ! command -v xray >/dev/null 2>&1; then
                installXray
            fi
            getuuid
            getname
            getkey
            getip
            getport
            setFirewall
            getdest
            getsid
            generate_config
            restart
            print_config
            generate_link
            ;;
        5)
            generate_link
            ;;
        6)
            checkSystem
            preinstall
            Modify_xrayconfig
            generate_config
            restart
            print_config
            generate_link
            ;;
        7)
            checkSystem
            start
            Xray
            ;;
        8)
            checkSystem
            restart
            Xray
            ;;
        9)
            checkSystem
            stop
            Xray
            ;;
        10)
            menu
            ;;
        *)
            colorEcho "$RED" "请选择正确的操作！"
            exit 1
            ;;
    esac
}

Xray
