#!/bin/bash

# ==================================================
# 路径与变量定义 (严禁变动)
# ==================================================
SB_CONF="/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
SB_CMD="/usr/local/bin/nusb"
SB_LOG="/var/log/sing-box.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ==================================================
# 1. 配置生成逻辑 (V1.12+ 兼容性)
# ==================================================
write_config() {
    local port=$1 uuid=$2 path=$3 host=$4
    local transport_json
    if [ -z "$host" ]; then
        transport_json='{"type":"ws","path":"'$path'","early_data_header_name":"Sec-WebSocket-Protocol"}'
    else
        transport_json='{"type":"ws","path":"'$path'","headers":{"host":"'$host'"},"early_data_header_name":"Sec-WebSocket-Protocol"}'
    fi

    cat <<EOF > $SB_CONF
{
  "log": { "level": "info", "timestamp": true, "output": "$SB_LOG" },
  "dns": {
    "servers": [
      { "tag": "dns-google", "address": "tls://8.8.8.8", "detour": "direct" },
      { "tag": "dns-cf", "address": "tls://1.1.1.1", "detour": "direct" }
    ],
    "rules": [],
    "final": "dns-google",
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "sniff": true,
      "sniff_override_destination": true,
      "users": [{ "uuid": "$uuid", "name": "user1" }],
      "transport": $transport_json
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv4" },
    { "type": "direct", "tag": "direct-v6", "domain_strategy": "prefer_ipv6" },
    { "type": "dns", "tag": "dns-out" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "port": 53, "outbound": "dns-out" },
      { "ip_cidr": ["0.0.0.0/0"], "outbound": "direct" },
      { "ip_cidr": ["::/0"], "outbound": "direct-v6" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

# ==================================================
# 2. 服务管理 (Systemd/OpenRC)
# ==================================================
setup_service() {
    touch $SB_LOG && chmod 666 $SB_LOG
    if [ -d "/run/systemd/system" ] || [ -d "/etc/systemd/system" ]; then
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=Sing-box Service
After=network.target
[Service]
Type=simple
Environment=ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
StandardOutput=append:$SB_LOG
StandardError=append:$SB_LOG
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable sing-box >/dev/null 2>&1
    elif [ -f "/etc/alpine-release" ]; then
        cat <<EOF > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="run -c $SB_CONF"
command_background=true
export ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS=true
output_log="$SB_LOG"
error_log="$SB_LOG"
EOF
        chmod +x /etc/init.d/sing-box && rc-update add sing-box default >/dev/null 2>&1
    fi
}

# ==================================================
# 3. nusb 管理工具 (增加 host/clear/conn/early)
# ==================================================
create_nusb_cmd() {
    cat <<EOF > $SB_CMD
#!/bin/bash
SB_CONF="$SB_CONF"
SB_BIN="$SB_BIN"
SB_LOG="$SB_LOG"

show_info() {
    IP=\$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ifconfig.me)
    PORT=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
    UUID=\$(jq -r '.inbounds[0].users[0].uuid' \$SB_CONF)
    PATH_RAW=\$(jq -r '.inbounds[0].transport.path' \$SB_CONF)
    HOST=\$(jq -r '.inbounds[0].transport.headers.host // ""' \$SB_CONF)
    ED_SET=\$(jq -r '.inbounds[0].transport.early_data_header_name // ""' \$SB_CONF)
    
    LINK="vless://\$UUID@\$IP:\$PORT?type=ws&encryption=none&path=\${PATH_RAW//\//%2F}"
    [[ -n "\$HOST" ]] && LINK="\$LINK&host=\$HOST"
    [[ "\$ED_SET" == "Sec-WebSocket-Protocol" ]] && LINK="\$LINK&headerType=http"
    LINK="\$LINK#nusb-\$IP"

    echo -e "${GREEN}==================================================${PLAIN}"
    echo -e "服务器地址: ${CYAN}\$IP${PLAIN}"
    echo -e "监听端口  : ${CYAN}\$PORT${PLAIN}"
    echo -e "用户 UUID : ${CYAN}\$UUID${PLAIN}"
    echo -e "WS 路径   : ${CYAN}\$PATH_RAW${PLAIN}"
    echo -e "WS Host   : ${CYAN}\${HOST:-未设置}${PLAIN}"
    [ "\$ED_SET" == "Sec-WebSocket-Protocol" ] && E_STATUS="${GREEN}开启${PLAIN}" || E_STATUS="${RED}禁用${PLAIN}"
    echo -e "延迟优化  : \$E_STATUS"
    echo -e "--------------------------------------------------"
    echo -e "通用订阅链接:"
    echo -e "${YELLOW}\$LINK${PLAIN}"
    echo -e "${GREEN}==================================================${PLAIN}"
}

manage_service() {
    if command -v systemctl >/dev/null 2>&1; then systemctl \$1 sing-box;
    elif command -v rc-service >/dev/null 2>&1; then rc-service sing-box \$1; fi
}

case "\$1" in
    start) manage_service start && echo "已启动";;
    stop) manage_service stop && echo "已停止";;
    restart) manage_service restart && echo "已重启";;
    status) pgrep -f \$SB_BIN > /dev/null && (echo -e "状态: ${GREEN}运行中${PLAIN}"; show_info) || echo -e "状态: ${RED}未运行${PLAIN}";;
    log) tail -n 50 -f \$SB_LOG ;;
    clear) > \$SB_LOG && echo "日志已清空" ;;
    conn)
        PORT=\$(jq -r '.inbounds[0].listen_port' \$SB_CONF)
        CONNS=\$(ss -antp | grep ":\$PORT" | grep "ESTAB")
        [ -z "\$CONNS" ] && echo "无活跃连接" || (echo "总数: \$(echo "\$CONNS" | wc -l)"; echo "\$CONNS" | awk '{print \$5}' | cut -d: -f1 | sort | uniq -c | sort -nr) ;;
    port) read -p "新端口: " P && jq ".inbounds[0].listen_port = \${P:-\$((RANDOM % 20000 + 30000))}" \$SB_CONF > /tmp/sb.json && mv /tmp/sb.json \$SB_CONF && \$0 restart ;;
    uuid) read -p "新 UUID: " U && jq ".inbounds[0].users[0].uuid = \"\${U:-\$(cat /proc/sys/kernel/random/uuid)}\"" \$SB_CONF > /tmp/sb.json && mv /tmp/sb.json \$SB_CONF && \$0 restart ;;
    path) read -p "新路径: " PA && jq ".inbounds[0].transport.path = \"\${PA:-/\$(openssl rand -hex 4)}\"" \$SB_CONF > /tmp/sb.json && mv /tmp/sb.json \$SB_CONF && \$0 restart ;;
    host) read -p "新 Host: " H && ( [ -z "\$H" ] && jq 'del(.inbounds[0].transport.headers)' \$SB_CONF || jq ".inbounds[0].transport.headers = {\"host\": \"\$H\"}" \$SB_CONF ) > /tmp/sb.json && mv /tmp/sb.json \$SB_CONF && \$0 restart ;;
    early)
        CUR=\$(jq -r '.inbounds[0].transport.early_data_header_name' \$SB_CONF)
        [ "\$CUR" == "Sec-WebSocket-Protocol" ] && jq 'del(.inbounds[0].transport.early_data_header_name)' \$SB_CONF > /tmp/sb.json || jq '.inbounds[0].transport.early_data_header_name = "Sec-WebSocket-Protocol"' \$SB_CONF > /tmp/sb.json
        mv /tmp/sb.json \$SB_CONF && \$0 restart ;;
    *) echo -e "用法: nusb {start|stop|restart|status|early|conn|log|clear|port|uuid|path|host}";;
esac
EOF
    chmod +x $SB_CMD
}

# ==================================================
# 4. 业务逻辑
# ==================================================
do_install() {
    OS_TYPE=$(test -f /etc/alpine-release && echo "alpine" || echo "debian")
    ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"; [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
    if [ "$OS_TYPE" = "alpine" ]; then apk add --no-cache curl jq openssl; else apt-get update && apt-get install -y curl jq openssl; fi

    echo -e "${CYAN}--- 配置初始化 (回车则随机/默认) ---${PLAIN}"
    read -p "1. 监听端口: " IPORT
    read -p "2. 用户 UUID: " IUUID
    read -p "3. WS 路径: " IPATH
    read -p "4. WS Host (可选): " IHOST

    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    curl -L "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz" -o sb.tar.gz
    tar -zxvf sb.tar.gz && cp sing-box-*/sing-box $SB_BIN && chmod +x $SB_BIN && rm -rf sb.tar.gz sing-box-*

    mkdir -p /etc/sing-box
    write_config "${IPORT:-$((RANDOM % 20000 + 30000))}" "${IUUID:-$(cat /proc/sys/kernel/random/uuid)}" "${IPATH:-/$(openssl rand -hex 4)}" "$IHOST"
    setup_service
    create_nusb_cmd
    $SB_CMD restart && clear && $SB_CMD status
}

# ==================================================
# 5. 主菜单 (使用正确的 break 逻辑)
# ==================================================
while true; do
    clear
    echo -e "${CYAN}Sing-box 运维脚本 V10.0 (逻辑修复版)${PLAIN}"
    echo -e "1. 安装/覆盖安装\n2. 卸载\n3. 查看详情 (nusb)\n0. 退出"
    read -p "选择: " choice
    case "$choice" in
        1) do_install; echo "回车继续..."; read ;;
        2) (pkill -f $SB_BIN; rm -rf $SB_BIN $SB_CMD $SB_LOG /etc/sing-box; echo "已卸载"); echo "回车继续..."; read ;;
        3) [ -f $SB_CMD ] && $SB_CMD status || echo "未安装！"; echo "回车继续..."; read ;;
        0) break ;; # 这里 break 在 while 循环内，是合法的
        *) echo "无效选项！"; sleep 1 ;;
    esac
done
