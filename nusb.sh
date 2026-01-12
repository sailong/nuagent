#!/bin/bash

# ==================================================
# 路径与变量定义
# ==================================================
SB_CONF="/etc/sing-box/config.json"
SB_META="/etc/sing-box/nusb.meta"
SB_BACKUP="/etc/sing-box/backups"
SB_BIN="/usr/local/bin/sing-box"
SB_CMD="/usr/local/bin/nusb"
SB_LOG="/var/log/sing-box.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ==================================================
# 1. 辅助工具：进度条模拟
# ==================================================
show_progress() {
    local duration=$1
    local task_name=$2
    echo -ne "${YELLOW}[任务] ${task_name}...${PLAIN}\n"
    echo -ne "进度: [....................] 0%"
    for i in {1..20}; do
        sleep $(echo "scale=2; $duration/20" | bc)
        echo -ne "\r进度: ["
        for ((j=0; j<i; j++)); do echo -ne "#"; done
        for ((j=i; j<20; j++)); do echo -ne "."; done
        echo -ne "] $((i*5))%"
    done
    echo -e " ${GREEN}完成!${PLAIN}\n"
}

# ==================================================
# 2. 核心逻辑：自动备份
# ==================================================
do_backup() {
    if [ -f "$SB_CONF" ]; then
        mkdir -p "$SB_BACKUP"
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$SB_CONF" "$SB_BACKUP/config_$timestamp.json.bak"
        [ -f "$SB_META" ] && cp "$SB_META" "$SB_BACKUP/meta_$timestamp.meta.bak"
        (ls -t $SB_BACKUP/config_*.bak | tail -n +11 | xargs rm -f) 2>/dev/null
    fi
}

# ==================================================
# 3. 配置生成 (V17.0+ 架构解耦纯净版)
# ==================================================
write_config() {
    local port=$1 uuid=$2 path=$3 host=$4 sni=$5 listen_ip=$6
    do_backup
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
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [ { "protocol": "dns", "outbound": "dns-out" } ],
    "auto_detect_interface": true
  }
}
EOF
}

# ==================================================
# 4. 反向代理插件 (Nginx/Caddy)
# ==================================================
setup_proxy() {
    local domain=$1 port=$2 path=$3 p_type=$4
    if [ "$p_type" == "nginx" ]; then
        mkdir -p /etc/nginx/conf.d
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
    }
}
EOF
        systemctl restart nginx
    elif [ "$p_type" == "caddy" ]; then
        if ! command -v caddy >/dev/null 2>&1; then
            apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -sL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list
            apt-get update && apt-get install caddy -y
        fi
        echo -e "$domain {\n    reverse_proxy $path 127.0.0.1:$port\n}" > /etc/caddy/Caddyfile
        systemctl enable caddy && systemctl restart caddy
    fi
}

# ==================================================
# 5. nusb 管理工具 (QR+Status+Log)
# ==================================================
create_nusb_cmd() {
    cat <<EOF > $SB_CMD
#!/bin/bash
SB_CONF="$SB_CONF"
SB_META="$SB_META"
SB_LOG="$SB_LOG"

get_link() {
    IP=\$(curl -s4m 5 api.ipify.org || curl -s4m 5 ifconfig.me)
    PORT=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
    UUID=\$(jq -r '.inbounds[0].users[0].uuid' \$SB_CONF)
    PATH_RAW=\$(jq -r '.inbounds[0].transport.path' \$SB_CONF)
    HOST=\$(jq -r '.inbounds[0].transport.headers.host // ""' \$SB_CONF)
    SNI=\$(grep "sni:" \$SB_META | cut -d: -f2)
    MODE=\$(grep "mode:" \$SB_META | cut -d: -f2)
    PATH_ENC=\$(echo -n "\$PATH_RAW" | jq -sRr @uri)
    
    if [ "\$MODE" == "127.0.0.1" ]; then
        echo "vless://\$UUID@\$SNI:443?encryption=none&security=tls&sni=\$SNI&fp=firefox&type=ws&host=\$SNI&path=\$PATH_ENC#Proxy-\$SNI"
    else
        echo "vless://\$UUID@\$IP:\$PORT?encryption=none&security=tls&sni=\$SNI&fp=firefox&type=ws&host=\$HOST&path=\$PATH_ENC#Direct-\$IP"
    fi
}

case "\$1" in
    status) LINK=\$(get_link); echo -e "${GREEN}订阅链接:${PLAIN}\n\${YELLOW}\$LINK\${PLAIN}" ;;
    qr) qrencode -t ansiutf8 "\$(get_link)" ;;
    log) tail -n 50 -f \$SB_LOG ;;
    restart) systemctl restart sing-box ;;
    clear) > \$SB_LOG && echo "日志已清空" ;;
    conn) 
        P=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
        ss -antp | grep ":\$P" | grep "ESTAB" | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -nr ;;
    *) echo "用法: nusb {status|qr|log|clear|conn|restart}" ;;
esac
EOF
    chmod +x $SB_CMD
}

# ==================================================
# 6. 主流程：安装程序 (完整无删减)
# ==================================================

do_install() {
    # 依赖检查
    OS_TYPE=$(test -f /etc/alpine-release && echo "alpine" || echo "debian")
    if [ "$OS_TYPE" = "debian" ]; then
        apt-get update && apt-get install -y curl jq openssl qrencode bc
    else
        apk add --no-cache curl jq openssl qrencode bc
    fi

    echo -e "${CYAN}--- 部署模式选择 ---${PLAIN}"
    echo -e "1. ${GREEN}直连模式${PLAIN} (适合 IP 直接访问)"
    echo -e "2. ${GREEN}反代模式${PLAIN} (适合域名 + 443 访问)"
    read -p "选择 [1-2]: " imode

    echo -e "${CYAN}--- 节点参数录入 (直接回车则随机/默认) ---${PLAIN}"
    read -p "1. 监听端口: " IPORT
    read -p "2. 用户 UUID: " IUUID
    read -p "3. WS 路径: " IPATH
    read -p "4. Host/SNI 域名: " IHOST

    # 停止旧进程解决 Busy
    systemctl stop sing-box >/dev/null 2>&1
    pkill -f sing-box >/dev/null 2>&1
    sleep 1

    # 下载安装核心
    ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    echo -e "${YELLOW}正在安装 Sing-box v$LATEST_VER ($ARCH)...${PLAIN}"
    curl -L "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz" -o sb.tar.gz
    tar -zxvf sb.tar.gz && cp -f sing-box-*/sing-box $SB_BIN && chmod +x $SB_BIN && rm -rf sb.tar.gz sing-box-*

    mkdir -p /etc/sing-box
    if [ "$imode" == "2" ]; then
        # 反代模式：内部监听 127.0.0.1
        write_config "${IPORT:-$((RANDOM%10000+20000))}" "${IUUID:-$(cat /proc/sys/kernel/random/uuid)}" "${IPATH:-/$(openssl rand -hex 4)}" "$IHOST" "$IHOST" "127.0.0.1"
        echo -e "请选择反代组件: 1. Nginx  2. Caddy"
        read -p "选择 [1-2]: " pchoice
        [ "$pchoice" == "1" ] && setup_proxy "$IHOST" "$(jq -r '.inbounds[0].listen_port' $SB_CONF)" "$(jq -r '.inbounds[0].transport.path' $SB_CONF)" "nginx"
        [ "$pchoice" == "2" ] && setup_proxy "$IHOST" "$(jq -r '.inbounds[0].listen_port' $SB_CONF)" "$(jq -r '.inbounds[0].transport.path' $SB_CONF)" "caddy"
    else
        # 直连模式：监听公网 ::
        write_config "${IPORT:-443}" "${IUUID:-$(cat /proc/sys/kernel/random/uuid)}" "${IPATH:-/$(openssl rand -hex 4)}" "$IHOST" "$IHOST" "::"
    fi

    # 注册系统服务
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service
After=network.target
[Service]
Environment=ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
StandardOutput=append:$SB_LOG
StandardError=append:$SB_LOG
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box
    create_nusb_cmd
    clear && $SB_CMD qr && $SB_CMD status
}

# ==================================================
# 7. 主流程：卸载程序 (视觉引导增强版)
# ==================================================
do_uninstall() {
    clear
    echo -e "${RED}！！！ 警告：即将开始深度卸载 ！！！${PLAIN}"
    read -p "确定执行吗？(y/n): " confirm
    [[ "$confirm" != [yY] ]] && return

    show_progress 1 "停止 Sing-box 核心服务"
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service

    if [ -f "/etc/nginx/conf.d/singbox.conf" ]; then
        show_progress 0.5 "清理 Nginx 反代配置"
        rm -f /etc/nginx/conf.d/singbox.conf
        systemctl restart nginx >/dev/null 2>&1
        read -p "是否彻底卸载 Nginx？ [y/N]: " un_ng
        [[ "$un_ng" == [yY] ]] && apt-get purge nginx -y >/dev/null 2>&1
    fi

    if command -v caddy >/dev/null 2>&1; then
        read -p "检测到 Caddy，是否彻底卸载及清理证书数据？ [y/N]: " un_cd
        if [[ "$un_cd" == [yY] ]]; then
            show_progress 1.2 "正在物理粉碎 Caddy 软件"
            systemctl stop caddy >/dev/null 2>&1
            apt-get purge caddy -y >/dev/null 2>&1
            rm -rf /etc/caddy /var/lib/caddy
        fi
    fi

    show_progress 0.8 "清理残留文件与元数据"
    rm -rf /etc/sing-box $SB_BIN $SB_CMD $SB_LOG
    systemctl daemon-reload

    echo -e "${GREEN}卸载完成！建议运行 'ss -ntlp' 确认端口已释放。${PLAIN}"
}

# ==================================================
# 8. 主菜单入口
# ==================================================
while true; do
    clear
    echo -e "${CYAN}##################################################${PLAIN}"
    echo -e "${CYAN}#        Sing-box 终极运维脚本 V19.4 完整版        #${PLAIN}"
    echo -e "${CYAN}##################################################${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 安装/覆盖安装节点 (支持 Nginx/Caddy 反代)"
    echo -e "  ${RED}2. 深度卸载 (含进度展示与组件清理)${PLAIN}"
    echo -e "  ${GREEN}3.${PLAIN} 查看详情 (nusb status)"
    echo -e "  ${PLAIN}0. 退出${PLAIN}"
    echo -e "${CYAN}--------------------------------------------------${PLAIN}"
    read -p "请选择 [0-3]: " choice
    case "$choice" in
        1) do_install; echo -e "\n${YELLOW}操作完成。回车返回菜单...${PLAIN}"; read ;;
        2) do_uninstall; echo -e "\n${YELLOW}操作完成。回车返回菜单...${PLAIN}"; read ;;
        3) [ -f $SB_CMD ] && $SB_CMD status || echo "未安装！"; echo -e "\n回车返回..."; read ;;
        0) exit 0 ;;
        *) echo "无效选项！"; sleep 1 ;;
    esac
done
