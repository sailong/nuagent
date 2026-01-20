#!/bin/bash

# ==================================================
# 0. 基础配置
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行！${PLAIN}" && exit 1

SB_BIN="/usr/local/bin/sing-box"
CF_BIN="/usr/local/bin/cloudflared"
SB_DIR="/etc/sing-box"
SB_CONF="$SB_DIR/config.json"
SB_DB="$SB_DIR/nodes.db"
SB_CERT="$SB_DIR/cert"

# 架构检测
ARCH=$(uname -m)
case $ARCH in
    x86_64)  S_ARCH="amd64"; C_ARCH="amd64" ;;
    aarch64) S_ARCH="arm64"; C_ARCH="arm64" ;;
    armv7l)  S_ARCH="armv7"; C_ARCH="arm"   ;;
    *)       echo -e "${RED}不支持的架构: $ARCH${PLAIN}" && exit 1 ;;
esac

# ==================================================
# 镜像选择逻辑
# ==================================================
echo -e "${YELLOW}网络环境选择:${PLAIN}"
echo -e " 1. 国内服务器 (自定义/默认加速镜像)"
echo -e " 2. 海外服务器 (官方源)"
read -p "请选择 (默认1): " net_opt

if [[ "$net_opt" == "2" ]]; then
    PROXY=""
else
    DEFAULT_PROXY="https://mirror.ghproxy.com/"
    echo -e "${CYAN}请输入加速镜像地址 (需以 http 开头，以 / 结尾)${PLAIN}"
    echo -e "例如: https://ghproxy.net/ 或 https://gh.api.999888.xyz/"
    read -p "留空则使用默认 [${DEFAULT_PROXY}]: " user_mirror
    if [[ -z "$user_mirror" ]]; then PROXY="$DEFAULT_PROXY"; else PROXY="$user_mirror"; fi
    echo -e "${GREEN}当前使用镜像: ${PROXY}${PLAIN}"
fi

# ==================================================
# 1. 基础依赖安装
# ==================================================
install_deps() {
    echo -e "${YELLOW}正在检查并安装依赖...${PLAIN}"
    if [ -f /etc/alpine-release ]; then
        apk update && apk add bash curl wget tar jq openssl iptables tzdata
    elif [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y curl wget tar jq openssl iptables
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl wget tar jq openssl iptables
    fi
    mkdir -p "$SB_DIR" "$SB_CERT"
    [ ! -f "$SB_DB" ] && touch "$SB_DB"
}

# ==================================================
# 2. 安装 Sing-box
# ==================================================
install_sb() {
    install_deps
    echo -e "${YELLOW}正在安装 Sing-box...${PLAIN}"
    VER=$(curl -s ${PROXY}https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$VER" ] && VER="1.10.7"
    wget -O sb.tar.gz "${PROXY}https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${S_ARCH}.tar.gz"
    if [ ! -f "sb.tar.gz" ]; then echo -e "${RED}下载失败${PLAIN}"; return; fi
    tar -zxvf sb.tar.gz >/dev/null
    SB_TMP=$(find . -maxdepth 1 -type d -name "sing-box-*" | head -n 1)
    cp -f "$SB_TMP/sing-box" "$SB_BIN" && chmod +x "$SB_BIN"
    rm -rf sb.tar.gz "$SB_TMP"
    
    # 初始化配置
    echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$SB_CONF"
    
    # 启动服务
    if [ -d /run/systemd/system ]; then
        echo -e "[Unit]\nDescription=sing-box\nAfter=network.target\n[Service]\nExecStart=$SB_BIN run -c $SB_CONF\nRestart=always\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/sing-box.service
        systemctl daemon-reload && systemctl enable sing-box && systemctl restart sing-box
    else
        echo -e "#!/sbin/openrc-run\ncommand=\"$SB_BIN\"\ncommand_args=\"run -c $SB_CONF\"\ncommand_background=true\npidfile=\"/run/sing-box.pid\"" > /etc/init.d/sing-box
        chmod +x /etc/init.d/sing-box && rc-update add sing-box default && rc-service sing-box restart
    fi
    echo -e "${GREEN}Sing-box 安装完成！${PLAIN}"
}

# ==================================================
# 3. 安装并启动 Cloudflared
# ==================================================
install_cf() {
    install_deps
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    [ -z "$TOKEN" ] && echo -e "${RED}Token 不能为空${PLAIN}" && return
    echo -e "${YELLOW}正在安装 Cloudflared...${PLAIN}"
    wget -O "$CF_BIN" "${PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$C_ARCH"
    chmod +x "$CF_BIN"
    echo -e "${YELLOW}正在启动 Tunnel...${PLAIN}"
    if [ -d /run/systemd/system ]; then
        $CF_BIN service uninstall >/dev/null 2>&1
        $CF_BIN service install "$TOKEN"
        systemctl start cloudflared && systemctl enable cloudflared
    else
        echo -e "#!/sbin/openrc-run\ncommand=\"$CF_BIN\"\ncommand_args=\"tunnel run --token $TOKEN\"\ncommand_background=true\npidfile=\"/run/cloudflared.pid\"" > /etc/init.d/cloudflared
        chmod +x /etc/init.d/cloudflared && rc-update add cloudflared default && rc-service cloudflared restart
    fi
    echo -e "${GREEN}Cloudflared 启动成功！${PLAIN}"
}

# ==================================================
# 4. 添加节点
# ==================================================
add_node() {
    [ ! -f "$SB_BIN" ] && echo -e "${RED}请先安装 Sing-box${PLAIN}" && return
    echo -e "${CYAN}--- 添加节点 ---${PLAIN}"
    echo -e " ${YELLOW}[配合 CF Tunnel/CDN]${PLAIN}"
    echo -e " 1. VLESS + WS (明文)"
    echo -e " 2. Trojan + WS (明文)"
    echo -e " ${YELLOW}[直连 - 推荐]${PLAIN}"
    echo -e " 3. ${GREEN}VLESS + REALITY${PLAIN} (抗封锁/无证书)"
    echo -e " 4. ${GREEN}Hysteria 2${PLAIN} (暴力UDP/自签证书)"
    read -p "选择: " type
    
    read -p "监听端口 (Reality建议443): " port
    if grep -q "|$port|" "$SB_DB"; then echo -e "${RED}端口已占用${PLAIN}"; return; fi

    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    case "$type" in
        1|2) # WS 模式
            echo -e "${YELLOW}请输入你 Cloudflare Tunnel 绑定的域名${PLAIN}"
            read -p "绑定域名 (例: tunnel.abc.com): " domain
            read -p "WS 路径 (回车自动随机): " input_path
            [ -z "$input_path" ] && path="/$(openssl rand -hex 4)" || ([[ "$input_path" != /* ]] && path="/$input_path" || path="$input_path")
            
            if [ "$type" == "1" ]; then
                json="{\"type\":\"vless\",\"tag\":\"vless-$port\",\"listen\":\"::\",\"listen_port\":$port,\"users\":[{\"uuid\":\"$uuid\"}],\"transport\":{\"type\":\"ws\",\"path\":\"$path\"}}"
                db="vless|$port|$uuid|$path|$domain"
            else
                pwd=$(openssl rand -base64 12)
                json="{\"type\":\"trojan\",\"tag\":\"trojan-$port\",\"listen\":\"::\",\"listen_port\":$port,\"users\":[{\"password\":\"$pwd\"}],\"transport\":{\"type\":\"ws\",\"path\":\"$path\"}}"
                db="trojan|$port|$pwd|$path|$domain"
            fi
            ;;
        
        3) # Reality 模式
            echo -e "${YELLOW}请输入伪装域名 (无需是你自己的，回车默认 www.microsoft.com)${PLAIN}"
            read -p "伪装域名: " sni
            [ -z "$sni" ] && sni="www.microsoft.com"
            keys=$($SB_BIN generate reality-keypair)
            pk=$(echo "$keys" | grep "Private key" | awk '{print $3}')
            pub=$(echo "$keys" | grep "Public key" | awk '{print $3}')
            sid=$(openssl rand -hex 8)
            json="{\"type\":\"vless\",\"tag\":\"reality-$port\",\"listen\":\"::\",\"listen_port\":$port,\"users\":[{\"uuid\":\"$uuid\"}],\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$sni\",\"server_port\":443},\"private_key\":\"$pk\",\"short_id\":[\"$sid\"]}}}"
            db="reality|$port|$uuid|$pub|$sid|$sni"
            ;;

        4) # Hy2 模式
            echo -e "${YELLOW}正在生成自签名证书 (有效期10年)...${PLAIN}"
            openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$SB_CERT/hy2.key" -out "$SB_CERT/hy2.crt" -days 3650 -subj "/CN=bing.com" 2>/dev/null
            read -p "认证密码 (回车随机): " hpwd
            [ -z "$hpwd" ] && hpwd=$(openssl rand -base64 12)
            json="{\"type\":\"hysteria2\",\"tag\":\"hy2-$port\",\"listen\":\"::\",\"listen_port\":$port,\"users\":[{\"password\":\"$hpwd\"}],\"tls\":{\"enabled\":true,\"certificate_path\":\"$SB_CERT/hy2.crt\",\"key_path\":\"$SB_CERT/hy2.key\"}}"
            db="hy2|$port|$hpwd"
            ;;
        *) return ;;
    esac
    
    tmp=$(mktemp)
    jq ".inbounds += [$json]" "$SB_CONF" > "$tmp" && mv "$tmp" "$SB_CONF"
    echo "$db" >> "$SB_DB"
    if [ -d /run/systemd/system ]; then systemctl restart sing-box; else rc-service sing-box restart; fi
    echo -e "${GREEN}节点添加成功！${PLAIN}"
}

# ==================================================
# 5. 查看节点连接
# ==================================================
show_nodes() {
    clear
    [ ! -f "$SB_DB" ] && echo "无节点数据" && return
    ip=$(curl -s4 api.ipify.org)
    CF_IP="www.visa.com.sg"
    
    echo -e "${CYAN}--- 节点订阅链接 ---${PLAIN}"
    while IFS='|' read -r type port auth p1 p2 p3; do
        if [ "$type" == "vless" ]; then
            path_enc=$(echo -n "$p1" | jq -sRr @uri)
            echo -e "${GREEN}VLESS (CF Tunnel):${PLAIN}"
            echo -e "vless://$auth@$CF_IP:443?encryption=none&security=tls&sni=$p2&fp=firefox&type=ws&host=$p2&path=$path_enc#$p2"
        elif [ "$type" == "trojan" ]; then
            path_enc=$(echo -n "$p1" | jq -sRr @uri)
            echo -e "${GREEN}Trojan (CF Tunnel):${PLAIN}"
            echo -e "trojan://$auth@$CF_IP:443?security=tls&sni=$p2&type=ws&host=$p2&path=$path_enc#$p2"
        elif [ "$type" == "reality" ]; then
            echo -e "${GREEN}VLESS + Reality (直连):${PLAIN}"
            echo -e "vless://$auth@$ip:$port?security=reality&sni=$p3&fp=firefox&pbk=$p1&sid=$p2&type=tcp&headerType=none#Reality-$port"
        elif [ "$type" == "hy2" ]; then
            echo -e "${GREEN}Hysteria 2 (直连/自签):${PLAIN}"
            echo -e "hysteria2://$auth@$ip:$port?insecure=1&sni=bing.com#Hy2-$port"
        fi
        echo "------------------------"
    done < "$SB_DB"
    read -p "按回车返回..."
}

# ==================================================
# 6. BBR 管理 (V47.0 状态感知)
# ==================================================
get_bbr_status() {
    local algo=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$algo" == "bbr" ]]; then
        BBR_STATUS="${GREEN}已开启${PLAIN}"
    else
        BBR_STATUS="${RED}未开启${PLAIN}"
    fi
}

enable_bbr() {
    echo -e "${YELLOW}正在检测系统环境...${PLAIN}"
    
    # 检查内核版本 >= 4.9
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)
    if [[ $KERNEL_MAJOR -lt 4 ]] || ([[ $KERNEL_MAJOR -eq 4 ]] && [[ $KERNEL_MINOR -lt 9 ]]); then
        echo -e "${RED}内核版本过低 ($(uname -r))，BBR 需要 4.9+。无法开启。${PLAIN}"
        return
    fi

    echo -e "${YELLOW}正在配置 BBR...${PLAIN}"
    if [ ! -f /etc/sysctl.conf ]; then touch /etc/sysctl.conf; fi
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    
    get_bbr_status
    echo -e "操作完成，当前状态: $BBR_STATUS"
}

# ==================================================
# 7. 干净卸载
# ==================================================
uninstall_all() {
    if [ -d /run/systemd/system ]; then
        systemctl stop sing-box cloudflared 2>/dev/null
        systemctl disable sing-box cloudflared 2>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        [ -f "$CF_BIN" ] && $CF_BIN service uninstall 2>/dev/null
    else
        rc-service sing-box stop 2>/dev/null
        rc-service cloudflared stop 2>/dev/null
        rc-update del sing-box 2>/dev/null
        rc-update del cloudflared 2>/dev/null
        rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
    fi
    rm -rf "$SB_DIR" "$SB_BIN" "$CF_BIN"
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# ==================================================
# 菜单
# ==================================================
while true; do
    get_bbr_status
    clear
    echo -e "${CYAN}Sing-box 极简全能版 V47.0${PLAIN}"
    echo -e "1. 安装 Sing-box"
    echo -e "2. 安装并启动 Cloudflared"
    echo -e "3. 添加节点 ${YELLOW}(Reality/Hy2/WS)${PLAIN}"
    echo -e "4. 查看节点"
    echo -e "5. 干净卸载所有"
    echo -e "6. 开启/刷新 BBR 加速 [状态: ${BBR_STATUS}]"
    echo -e "0. 退出"
    read -p "选择: " num
    case "$num" in
        1) install_sb; read -p "按回车..." ;;
        2) install_cf; read -p "按回车..." ;;
        3) add_node; read -p "按回车..." ;;
        4) show_nodes ;;
        5) uninstall_all; read -p "按回车..." ;;
        6) enable_bbr; read -p "按回车..." ;;
        0) exit 0 ;;
    esac
done
