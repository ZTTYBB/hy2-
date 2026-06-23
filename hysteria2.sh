#!/usr/bin/env bash
#==========================================================================
#  Hysteria 2 一键自动安装脚本 (超轻量，适配 64MB，全自动)
#  支持: Debian/Ubuntu, CentOS/RHEL/Rocky/Alma, Alpine, OpenWrt 等
#  默认: 随机端口+随机密码，自动选择最优伪装域名，无交互
#  可通过环境变量自定义:
#    HY2_PORT       监听端口
#    HY2_PASSWORD   认证密码
#    HY2_DOMAIN     伪装域名 (若留空则自动测试选择)
#==========================================================================
set -e

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# root 检查
[[ $EUID -eq 0 ]] || { echo -e "${RED}请使用 root 运行${NC}"; exit 1; }

# ----- 系统检测 -----
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ -f /etc/alpine-release ]; then
    OS=alpine
else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
fi
echo -e "${GREEN}操作系统: ${OS}${NC}"

# ----- 内存与自动 swap (64MB 极低内存) -----
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_MB=$(( TOTAL_MEM / 1024 ))
SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_MEM" -le 65536 ] && [ "$SWAP_TOTAL" -eq 0 ]; then
    echo -e "${YELLOW}内存 ${MEM_MB}MB 且无 swap，自动创建 64MB swap...${NC}"
    dd if=/dev/zero of=/swapfile bs=1M count=64 >/dev/null 2>&1
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1
    SWAP_CREATED=1
fi

# ----- 工具函数 -----
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) encoded+="$c" ;;
            * ) printf -v hex '%%%02X' "'$c"; encoded+="$hex" ;;
        esac
    done
    echo "$encoded"
}

test_latency() {
    local d=$1
    if command -v curl &> /dev/null; then
        local t=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 4 "https://$d" 2>/dev/null || echo "9999")
        if [[ "$t" =~ ^[0-9.]+$ ]]; then awk "BEGIN {printf \"%d\", $t*1000}"; else echo "9999"; fi
    else
        local p=$(ping -c 2 -W 2 "$d" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | sed 's/ ms//')
        if [[ "$p" =~ ^[0-9.]+$ ]]; then awk "BEGIN {printf \"%d\", $p}"; else echo "9999"; fi
    fi
}

gen_pass() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 12
    else cat /dev/urandom | tr -dc '0-9a-f' | fold -w 24 | head -n 1; fi
}

# ----- 最小依赖安装 -----
install_deps() {
    local miss=""
    for cmd in curl openssl tar ss; do
        command -v $cmd >/dev/null 2>&1 || miss+="$cmd "
    done
    [ -z "$miss" ] && return
    echo -e "${YELLOW}安装依赖: $miss${NC}"
    case $OS in
        ubuntu|debian) apt-get update -qq; apt-get install --no-install-recommends -y -qq $miss >/dev/null ;;
        centos|rhel|rocky|almalinux|fedora) yum install -y -q $miss 2>/dev/null || dnf install -y -q $miss >/dev/null ;;
        alpine) apk add --no-cache $miss >/dev/null ;;
        openwrt) opkg update >/dev/null 2>&1; opkg install $miss >/dev/null 2>&1 ;;
        *) echo -e "${RED}未知包管理器，请手动安装: $miss${NC}"; exit 1 ;;
    esac
}

# ----- 下载 Hysteria 2 (自动选择 musl/glibc) -----
download_hysteria() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64"  ;;
        armv7l)  ARCH="arm"    ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; exit 1 ;;
    esac

    # 检测 musl libc
    local LIBC=""
    if ldd /bin/sh 2>/dev/null | grep -qi musl || [ "$OS" = "alpine" ]; then
        LIBC="-musl"
    fi

    # 获取最新版本
    LATEST=$(curl -s --connect-timeout 10 https://api.github.com/repos/apernet/hysteria/releases/latest | awk -F'"' '/"tag_name":/ {print $4}')
    [ -z "$LATEST" ] && LATEST="v2.4.0"
    echo -e "${GREEN}安装 Hysteria ${LATEST}${NC}"

    URL="https://github.com/apernet/hysteria/releases/download/${LATEST}/hysteria-linux-${ARCH}${LIBC}"
    curl -L --progress-bar -o /usr/local/bin/hysteria "$URL"
    chmod +x /usr/local/bin/hysteria
    mkdir -p /etc/hysteria
}

# ----- 自签证书 -----
generate_cert() {
    openssl req -newkey rsa:2048 -nodes -keyout /etc/hysteria/hysteria.key \
        -x509 -days 3650 -out /etc/hysteria/hysteria.crt -subj "/CN=Hysteria2" 2>/dev/null
    chmod 600 /etc/hysteria/hysteria.key
    chmod 644 /etc/hysteria/hysteria.crt
}

# ----- 防火墙 (仅提示) -----
configure_firewall() {
    local p=$1
    if command -v ufw &>/dev/null; then
        ufw allow $p/udp >/dev/null 2>&1 && echo -e "${GREEN}UFW 放行 ${p}/udp${NC}"
        ufw status | grep -q inactive && echo -e "${YELLOW}UFW 未启用${NC}"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${p}/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}firewalld 放行 ${p}/udp${NC}"
    else
        echo -e "${YELLOW}未发现防火墙，请手动放行 UDP ${p}${NC}"
    fi
}

# ----- 服务安装 (systemd / OpenRC) -----
install_service() {
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
MemoryMax=40M
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-server >/dev/null 2>&1
        systemctl restart hysteria-server
        sleep 2
        if systemctl is-active --quiet hysteria-server; then
            echo -e "${GREEN}systemd 服务已运行${NC}"
        else
            echo -e "${RED}启动失败，日志: journalctl -u hysteria-server${NC}"; exit 1
        fi
    elif command -v rc-service &>/dev/null; then
        cat > /etc/init.d/hysteria-server <<'EOF'
#!/sbin/openrc-run
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria.pid"
EOF
        chmod +x /etc/init.d/hysteria-server
        rc-update add hysteria-server default >/dev/null 2>&1
        rc-service hysteria-server start >/dev/null 2>&1
        sleep 2
        if rc-service hysteria-server status | grep -q started; then
            echo -e "${GREEN}OpenRC 服务已运行${NC}"
        else
            echo -e "${RED}OpenRC 启动失败${NC}"; exit 1
        fi
    else
        echo -e "${YELLOW}未找到 systemd/OpenRC，请手动启动: hysteria server -c /etc/hysteria/config.yaml &${NC}"
    fi
}

# ----- 主流程 -----
main() {
    install_deps
    download_hysteria

    # 1. 伪装域名自动选择 (可通过 HY2_DOMAIN 覆盖)
    if [ -n "$HY2_DOMAIN" ]; then
        BEST_DOMAIN="$HY2_DOMAIN"
    else
        echo -e "${YELLOW}测试伪装网站延迟...${NC}"
        DOMAINS=(www.bing.com www.microsoft.com www.apple.com www.cloudflare.com www.amazon.com www.office.com www.live.com)
        BEST_DOMAIN=""
        BEST_TIME=9999
        for d in "${DOMAINS[@]}"; do
            lat=$(test_latency "$d")
            echo -e "  ${d} : ${lat} ms"
            [ "$lat" -lt "$BEST_TIME" ] && { BEST_TIME=$lat; BEST_DOMAIN=$d; }
        done
        if [ "$BEST_TIME" -ge 5000 ]; then
            echo -e "${YELLOW}所有预设域名不通，使用默认 www.bing.com${NC}"
            BEST_DOMAIN="www.bing.com"
        fi
    fi
    echo -e "${GREEN}伪装域名: ${BEST_DOMAIN}${NC}"

    # 2. 端口与密码 (环境变量优先，否则随机)
    PORT=${HY2_PORT:-$(shuf -i 10000-65000 -n 1)}
    PASSWORD=${HY2_PASSWORD:-$(gen_pass)}
    echo -e "${GREEN}端口: ${PORT}  密码: ${PASSWORD}${NC}"

    # 端口占用检查
    if command -v ss &>/dev/null; then
        ss -uln | grep -q ":${PORT} " && { echo -e "${RED}端口 ${PORT} 被占用${NC}"; exit 1; }
    fi

    generate_cert

    # 3. 动态调整 QUIC 窗口 (节约内存)
    if [ "$MEM_MB" -le 64 ]; then
        SWIN=524288; CWIN=2097152
    elif [ "$MEM_MB" -le 128 ]; then
        SWIN=1048576; CWIN=4194304
    elif [ "$MEM_MB" -le 256 ]; then
        SWIN=4194304; CWIN=10485760
    else
        SWIN=8388608; CWIN=20971520
    fi

    cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/hysteria.crt
  key: /etc/hysteria/hysteria.key

auth:
  type: password
  password: "$PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: https://${BEST_DOMAIN}
    rewriteHost: true

quic:
  initStreamReceiveWindow: $SWIN
  maxStreamReceiveWindow: $SWIN
  initConnReceiveWindow: $CWIN
  maxConnReceiveWindow: $CWIN
  maxIdleTimeout: 30s
  keepAliveInterval: 10s
EOF

    install_service
    configure_firewall $PORT

    # 公网 IP
    LOCAL_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || echo "未知")
    SHARE_LINK="hysteria2://$(urlencode "$PASSWORD")@${LOCAL_IP}:${PORT}?sni=${BEST_DOMAIN}&insecure=1#Hysteria2-${LOCAL_IP}"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${GREEN}   Hysteria 2 安装成功！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 服务器地址: ${LOCAL_IP}"
    echo -e " 端口:        ${PORT}"
    echo -e " 密码:        ${PASSWORD}"
    echo -e " 伪装域名:    ${BEST_DOMAIN}"
    echo -e " 协议:        UDP, 跳过证书验证"
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e " 分享链接:"
    echo -e " ${GREEN}${SHARE_LINK}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 配置文件: /etc/hysteria/config.yaml"
    [ "${SWAP_CREATED}" == "1" ] && echo -e "${YELLOW}已创建临时 swap (/swapfile)，可事后移除${NC}"
}

main
