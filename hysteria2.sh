#!/usr/bin/env bash
#==========================================================================
#  Hysteria 2 一键自动安装脚本 (终极 Alpine LXC 兼容版)
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

# ----- 依赖安装 -----
install_deps() {
    local CMD_MISSING=""
    ! command -v curl >/dev/null 2>&1 && CMD_MISSING+="curl "
    ! command -v openssl >/dev/null 2>&1 && CMD_MISSING+="openssl "
    ! command -v tar >/dev/null 2>&1 && CMD_MISSING+="tar "
    ! command -v ss >/dev/null 2>&1 && CMD_MISSING+="ss(iproute2) "
    [ -z "$CMD_MISSING" ] && return
    
    echo -e "${YELLOW}检测到缺失依赖: $CMD_MISSING，正在根据 $OS 系统自动安装...${NC}"
    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install --no-install-recommends -y -qq curl openssl tar iproute2 >/dev/null
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum install -y -q curl openssl tar iproute 2>/dev/null || dnf install -y -q curl openssl tar iproute >/dev/null
            ;;
        alpine)
            apk add --no-cache curl openssl tar iproute2 >/dev/null
            ;;
        openwrt)
            opkg update >/dev/null 2>&1
            opkg install curl openssl-util tar iproute2 >/dev/null 2>&1
            ;;
        *)
            echo -e "${RED}未能自动识别包管理器，请手动安装: $CMD_MISSING${NC}"
            exit 1
            ;;
    esac
}

# ----- 下载 Hysteria 2 -----
download_hysteria() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64"  ;;
        armv7l)  ARCH="arm"    ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; exit 1 ;;
    esac

    local LIBC=""
    if ldd /bin/sh 2>/dev/null | grep -qi musl || [ "$OS" = "alpine" ]; then
        LIBC="-musl"
    fi

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

# ----- 防火墙 -----
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

# ----- [终极修复版] 服务安装 (强制规避 Alpine 冲突) -----
install_service() {
    if [ "$OS" != "alpine" ] && command -v systemctl &>/dev/null; then
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
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-server >/dev/null 2>&1
        systemctl restart hysteria-server
        sleep 3
        if systemctl is-active --quiet hysteria-server; then
            echo -e "${GREEN}systemd 服务已运行${NC}"
        else
            echo -e "${RED}启动失败！查看具体原因: journalctl -u hysteria-server -n 20 --no-pager${NC}"
            journalctl -u hysteria-server -n 20 --no-pager
            exit 1
        fi
    elif command -v rc-service &>/dev/null || [ "$OS" = "alpine" ]; then
        echo -e "${YELLOW}检测到 OpenRC/Alpine 容器环境，使用 nohup 进程守护启动...${NC}"
        pkill -f "hysteria server" 2>/dev/null || true
        > /var/log/hysteria.log 2>/dev/null || touch /var/log/hysteria.log
        
        echo -e "${BLUE}正在执行启动前健康自检 (2秒)...${NC}"
        PRE_CHECK=$(timeout 2s /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml 2>&1 || true)
        if echo "$PRE_CHECK" | grep -qE "(panic|fatal|Error|permission denied|cannot allocate)"; then
            echo -e "${RED}【前置检查发现致命报错】${NC}"
            echo -e "${YELLOW}------------------------------------------------------${NC}"
            echo "$PRE_CHECK"
            echo -e "${YELLOW}------------------------------------------------------${NC}"
            echo -e "提示：如果提示 'permission denied'，请给 Docker/LXC 容器添加 --privileged 参数。"
            echo -e "提示：如果提示 'cannot allocate memory'，说明 64MB 跑不动，请尝试加到 128MB 内存。"
            exit 1
        fi
        
        echo -e "${BLUE}正式启动服务...${NC}"
        nohup bash -c "ulimit -s unlimited 2>/dev/null; export GOMEMLIMIT=48MiB; /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml" >> /var/log/hysteria.log 2>&1 &
        sleep 4
        
        if pgrep -f "hysteria server" > /dev/null; then
            echo -e "${GREEN}Hysteria 2 服务已通过 nohup 在后台成功运行！${NC}"
            echo -e "${YELLOW}注意：容器重启后需再次运行本脚本启动。${NC}"
        else
            echo -e "${RED}服务启动失败！抓取最终错误日志...${NC}"
            echo -e "${YELLOW}================================================${NC}"
            if [ -s /var/log/hysteria.log ]; then
                tail -n 30 /var/log/hysteria.log
            else
                echo -e "${RED}日志依然为空！可能是遭遇了极其严厉的 OOM 强杀。${NC}"
                echo -e "${YELLOW}请手动在终端执行以下命令查看最终爆出的错误：${NC}"
                echo "  /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml"
            fi
            echo -e "${YELLOW}================================================${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}未找到 systemd/OpenRC，请手动启动: hysteria server -c /etc/hysteria/config.yaml &${NC}"
    fi
}

# ----- 主流程 -----
main() {
    install_deps
    download_hysteria

    # 1. 伪装域名自动选择
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
        [ "$BEST_TIME" -ge 5000 ] && BEST_DOMAIN="www.bing.com"
    fi
    echo -e "${GREEN}伪装域名: ${BEST_DOMAIN}${NC}"

    # 2. 端口与密码
    PORT=${HY2_PORT:-$(shuf -i 10000-65000 -n 1)}
    PASSWORD=${HY2_PASSWORD:-$(gen_pass)}
    echo -e "${GREEN}端口: ${PORT}  密码: ${PASSWORD}${NC}"

    # 端口占用检查
    if command -v ss &>/dev/null; then
        ss -uln | grep -q ":${PORT} " && { echo -e "${RED}端口 ${PORT} 被占用${NC}"; exit 1; }
    fi

    generate_cert

    # 3. 动态调整 QUIC 窗口
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

    LOCAL_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || echo "未知")
    SHARE_LINK="hysteria2://$(urlencode "$PASSWORD")@${LOCAL_IP}:${PORT}?sni=${BEST_DOMAIN}&insecure=1#Hysteria2-${LOCAL_IP}"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${GREEN}   Hysteria 2 安装成功！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 服务器地址: ${LOCAL_IP}"
    echo -e " 端口:        ${PORT}"
    echo -e " 密码:        ${PASSWORD}"
    echo -e " 伪装域名:    ${BEST_DOMAIN}"
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e " 分享链接:"
    echo -e " ${GREEN}${SHARE_LINK}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e " 配置文件: /etc/hysteria/config.yaml"
    [ "${SWAP_CREATED}" == "1" ] && echo -e "${YELLOW}已创建临时 swap (/swapfile)，可事后移除${NC}"
}

main
