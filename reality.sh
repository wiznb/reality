#!/bin/bash
# REALITY一键安装脚本 (修正版)
# Author: YouTube频道<https://www.youtube.com/@aifenxiangdexiaoqie>

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

NAME="xray"
CONFIG_FILE="/usr/local/etc/${NAME}/config.json"
SERVICE_FILE="/etc/systemd/system/${NAME}.service"

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

checkSystem() {
    result=$(id | awk '{print $1}')
    if [[ $result != "uid=0(root)" ]]; then
        colorEcho $RED " 请以root身份执行该脚本"
        exit 1
    fi
    res=`which yum 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        res=`which apt 2>/dev/null`
        if [[ "$?" != "0" ]]; then
            colorEcho $RED " 不受支持的Linux系统"
            exit 1
        fi
        PMT="apt"
        CMD_INSTALL="apt install -y "
        CMD_REMOVE="apt remove -y "
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
    else
        PMT="yum"
        CMD_INSTALL="yum install -y "
        CMD_REMOVE="yum remove -y "
        CMD_UPGRADE="yum update -y"
    fi
    res=`which systemctl 2>/dev/null`
    if [[ "$?" != "0" ]]; then
        colorEcho $RED " 系统版本过低，请升级到最新版本"
        exit 1
    fi
}

# 生成UUID
getuuid() {
    echo "正在生成UUID..." 
    /usr/local/bin/xray uuid > /usr/local/etc/xray/uuid
    USER_UUID=$(cat /usr/local/etc/xray/uuid)
    colorEcho $BLUE "UUID：$USER_UUID"
}

# 节点名称
getname() {
    read -p "请输入您的节点名称，如果留空将保持默认：" USER_NAME
    [[ -z "$USER_NAME" ]] && USER_NAME="Reality(by小企鹅)"
    echo "$USER_NAME" > /usr/local/etc/xray/name
    colorEcho $BLUE "节点名称：$USER_NAME"
}

# 生成私钥和公钥
getkey() {
    echo "正在生成私钥和公钥..."
    /usr/local/bin/xray x25519 > /usr/local/etc/xray/key
    private_key=$(sed -n '1p' /usr/local/etc/xray/key | awk '{print $3}')
    public_key=$(sed -n '2p' /usr/local/etc/xray/key | awk '{print $3}')
    echo "$private_key" > /usr/local/etc/xray/privatekey
    echo "$public_key" > /usr/local/etc/xray/publickey
    colorEcho $BLUE "私钥：$private_key"
    colorEcho $BLUE "公钥：$public_key"
}

# 获取端口
getport() {
    while true; do
        read -p "请设置XRAY的端口号[1025-65535]，不输入则随机生成:" PORT
        [[ -z "$PORT" ]] && PORT=$(shuf -i1025-65000 -n1)
        if [[ $PORT -ge 1025 && $PORT -le 65535 ]]; then
            echo "$PORT" > /usr/local/etc/xray/port
            colorEcho $BLUE "端口号：$PORT"
            break
        else
            colorEcho $RED "输入错误，请输入1025-65535之间的数字"
        fi
    done
}

# shortId
getsid() {
    USER_SID=$(openssl rand -hex 8)
    echo $USER_SID > /usr/local/etc/xray/sid
    colorEcho $BLUE "shortID： $USER_SID"
}

# 生成配置文件
generate_config() {
    cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "debug"
  },
  "inbounds": [
    {
      "port": $(cat /usr/local/etc/xray/port),
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(cat /usr/local/etc/xray/uuid)",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$(cat /usr/local/etc/xray/dest)",
          "serverNames": [
            "$(cat /usr/local/etc/xray/servername)"
          ],
          "privateKey": "$(cat /usr/local/etc/xray/privatekey)",
          "shortIds": [
            "$(cat /usr/local/etc/xray/sid)"
          ]
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
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    echo "配置文件已生成完成..."
}

# 启动服务
start() {
    systemctl restart ${NAME}
    sleep 2
    systemctl status ${NAME} --no-pager -l
}

Xray() {
    checkSystem
    getuuid
    getname
    getkey
    getport
    getsid
    generate_config
    start
    echo "安装完成 ✅"
    echo "UUID: $(cat /usr/local/etc/xray/uuid)"
    echo "Public Key: $(cat /usr/local/etc/xray/publickey)"
    echo "shortID: $(cat /usr/local/etc/xray/sid)"
}
Xray
