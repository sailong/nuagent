#!/bin/bash

# ==================================================
# 路径定义
# ==================================================
SB_CONF="/etc/sing-box/config.json"
SB_META="/etc/sing-box/nusb.meta"
SB_BIN="/usr/local/bin/sing-box"
SB_CMD="/usr/local/bin/nusb"
SB_LOG="/var/log/sing-box.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ==================================================
# 1. 核心逻辑：配置文件生成
# ==================================================
write_config() {
    local port=$1 uuid=$2 path=$3 host=$4 sni=$5 listen_ip=$6
    
    # 存储元数据供 nusb 生成链接使用
    echo "sni:$sni" > "$SB_META"
    echo "mode:$listen_ip" >> "$SB_META"

    local transport_json
    if [ -z "$host" ]; then
        transport_json="{\"type\":\"ws\",\"path\":\"$path\",\"early_data_header_name\":\"Sec-WebSocket-Protocol\"}"
    else
        transport_json="{\"type\":\"ws\",\"path\":\"$path\",\"headers\":{\"host\":\"$host\"},\"early_data_header_name\":\"Sec-WebSocket-Protocol\"}"
    fi

    cat <<EOF > $SB_CONF
{
  "log": { "level": "info", "timestamp": true, "output": "$SB_LOG" },
  "dns": {
    "servers": [
      { "tag": "dns-google", "address": "tls://8.8.8.8", "detour": "direct" },
      { "tag": "dns-cf", "address": "tls://1.1.1.1", "detour": "direct" }
    ],
    "final": "dns-google",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "$listen_ip",
      "listen_port": $port,
      "sniff": true,
      "sniff_override_destination": true,
      "users": [{ "uuid": "$uuid", "name": "user1" }],
      "transport": $transport_json
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv4" },
    { "type": "dns", "tag": "dns-out" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "port": 53, "outbound": "dns-out" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

# ==================================================
# 2. 插件逻辑：反向代理配置 (Nginx/Caddy)
# ==================================================
setup_proxy() {
    local domain=$1 port=$2 path=$3 p_type=$4
    
    if [ "$p_type" == "nginx" ]; then
        echo -e "${YELLOW}正在配置 Nginx...${PLAIN}"
        [ ! -d "/etc/nginx/conf.d" ] && mkdir -p /etc/nginx/conf.d
        cat <<EOF > /etc/nginx/conf.d/singbox.conf
server {
    listen 80;
    server_name $domain;
    location $path {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
        systemctl restart nginx
    elif [ "$p_type" == "caddy" ]; then
        echo -e "${YELLOW}正在配置 Caddy...${PLAIN}"
        if ! command -v caddy >/dev/null 2>&1; then
            echo "未检测到 Caddy，正在安装..."
            debian_ver=$(curl -sL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt)
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            echo "$debian_ver" | tee /etc/apt/sources.list.d/caddy-stable.list
            apt-get update && apt-get install caddy -y
        fi
        echo -e "$domain {\n    reverse_proxy $path 127.0.0.1:$port\n}" > /etc/caddy/Caddyfile
        systemctl enable caddy && systemctl restart caddy
    fi
}

# 

# ==================================================
# 3. nusb 管理工具 (智能识别模式生成链接)
# ==================================================
create_nusb_cmd() {
    cat <<EOF > $SB_CMD
#!/bin/bash
SB_CONF="$SB_CONF"
SB_META="$SB_META"

get_link() {
    IP=\$(curl -s4m 5 api.ipify.org)
    PORT=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
    UUID=\$(jq -r '.inbounds[0].users[0].uuid' \$SB_CONF)
    PATH_RAW=\$(jq -r '.inbounds[0].transport.path' \$SB_CONF)
    HOST=\$(jq -r '.inbounds[0].transport.headers.host // ""' \$SB_CONF)
    SNI=\$(grep "sni:" \$SB_META | cut -d: -f2)
    MODE=\$(grep "mode:" \$SB_META | cut -d: -f2)
    PATH_ENC=\$(echo -n "\$PATH_RAW" | jq -sRr @uri)
    
    if [ "\$MODE" == "127.0.0.1" ]; then
        # 反代模式链接 (域名 + 443)
        echo "vless://\$UUID@\$SNI:443?encryption=none&security=tls&sni=\$SNI&fp=firefox&type=ws&host=\$SNI&path=\$PATH_ENC#Proxy-\$SNI"
    else
        # 直连模式链接 (IP + 原始端口)
        echo "vless://\$UUID@\$IP:\$PORT?encryption=none&security=tls&sni=\$SNI&fp=firefox&type=ws&host=\$HOST&path=\$PATH_ENC#Direct-\$IP"
    fi
}

case "\$1" in
    status)
        LINK=\$(get_link)
        echo -e "${GREEN}==================================================${PLAIN}"
        echo -e "订阅链接:\n${YELLOW}\$LINK${PLAIN}"
        echo -e "${GREEN}==================================================${PLAIN}"
        echo -e "提示: 输入 ${CYAN}nusb qr${PLAIN} 查看二维码" ;;
    qr) qrencode -t ansiutf8 "\$(get_link)" ;;
    log) tail -n 50 -f $SB_LOG ;;
    conn) 
        P=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
        ss -antp | grep ":\$P" | grep "ESTAB" | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -nr ;;
    restart) systemctl restart sing-box ;;
    *) echo -e "用法: nusb {status|qr|log|conn|restart}";;
esac
EOF
    chmod +x $SB_CMD
}

# ==================================================
# 4. 主安装程序 (增加模式选择菜单)
# ==================================================
do_install() {
    OS_TYPE=$(test -f /etc/alpine-release && echo "alpine" || echo "debian")
    ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
    if [ "$OS_TYPE" = "debian" ]; then apt-get update && apt-get install -y curl jq openssl qrencode; fi

    echo -e "${CYAN}--- 安装模式选择 ---${PLAIN}"
    echo -e "1. ${GREEN}直连模式${PLAIN} (Sing-box 监听公网，适合 IP 直连)"
    echo -e "2. ${GREEN}反代模式${PLAIN} (配合 Nginx/Caddy，适合域名 443 访问)"
    read -p "选择 [1-2]: " imode

    read -p "监听端口 (直连推荐443, 反代推荐随机): " IPORT
    read -p "用户 UUID (回车随机): " IUUID
    read -p "WS 路径 (回车随机): " IPATH
    read -p "Host/SNI 域名 (必须解析): " IHOST

    # 停止旧进程
    systemctl stop sing-box >/dev/null 2>&1; pkill -f sing-box >/dev/null 2>&1; sleep 1

    # 下载核心
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    curl -L "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz" -o sb.tar.gz
    tar -zxvf sb.tar.gz && cp -f sing-box-*/sing-box $SB_BIN && chmod +x $SB_BIN && rm -rf sb.tar.gz sing-box-*

    mkdir -p /etc/sing-box
    if [ "$imode" == "2" ]; then
        # 反代模式逻辑
        write_config "${IPORT:-$((RANDOM%10000+20000))}" "${IUUID:-$(cat /proc/sys/kernel/random/uuid)}" "${IPATH:-/$(openssl rand -hex 4)}" "$IHOST" "$IHOST" "127.0.0.1"
        echo -e "选择反代插件:\n1. Nginx\n2. Caddy"
        read -p "请选择 [1-2]: " pchoice
        [ "$pchoice" == "1" ] && setup_proxy "$IHOST" "$(jq -r '.inbounds[0].listen_port' $SB_CONF)" "$(jq -r '.inbounds[0].transport.path' $SB_CONF)" "nginx"
        [ "$pchoice" == "2" ] && setup_proxy "$IHOST" "$(jq -r '.inbounds[0].listen_port' $SB_CONF)" "$(jq -r '.inbounds[0].transport.path' $SB_CONF)" "caddy"
    else
        # 直连模式逻辑
        write_config "${IPORT:-443}" "${IUUID:-$(cat /proc/sys/kernel/random/uuid)}" "${IPATH:-/$(openssl rand -hex 4)}" "$IHOST" "$IHOST" "::"
    fi

    # 注册服务
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service
[Service]
Environment=ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box
    create_nusb_cmd
    clear && $SB_CMD qr && $SB_CMD status
}

# ==================================================
# 5. 主菜单入口
# ==================================================
while true; do
    clear
    echo -e "${CYAN}Sing-box 终极增强脚本 V19.0${PLAIN}"
    echo -e "1. 安装节点 (支持手动选择 Nginx/Caddy 反代)\n2. 卸载\n3. 查看详情\n0. 退出"
    read -p "选择: " choice
    case "$choice" in
        1) do_install; echo "回车返回..."; read ;;
        2) (systemctl stop sing-box; rm -rf /etc/sing-box $SB_BIN $SB_CMD; echo "已卸载"); read ;;
        3) [ -f $SB_CMD ] && $SB_CMD status || echo "未安装"; read ;;
        0) break ;;
    esac
done
