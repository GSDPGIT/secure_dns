#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: Linux DNS 极致净化与安全加固 (Systemd-Resolved + DoT) v2.0
# ==============================================================================

set -euo pipefail

# --- 核心配置 ---
readonly TARGET_DNS="8.8.8.8#dns.google 1.1.1.1#cloudflare-dns.com"
readonly CONF_CONTENT="[Resolve]
DNS=${TARGET_DNS}
LLMNR=no
MulticastDNS=no
DNSSEC=allow-downgrade
DNSOverTLS=yes
"

# --- 辅助函数 ---
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly NC="\033[0m"

log() { echo -e "${GREEN}--> $1${NC}"; }
log_warn() { echo -e "${YELLOW}[注意] $1${NC}"; }
log_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

# --- 1. 环境检测 ---
check_env() {
    export LC_ALL=C
    if [[ $EUID -ne 0 ]]; then
       log_error "权限不足：请使用 sudo 或 root 身份运行。"
       exit 1
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
            log_error "此脚本仅支持 Debian/Ubuntu 系统。"
            exit 1
        fi
    fi
    if ! command -v chattr &> /dev/null; then
        apt-get update -y && apt-get install -y e2fsprogs || true
    fi
}

# --- 2. 网络救援 ---
rescue_network() {
    log "正在检查并修复网络连通性..."
    if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then
        chattr -i "/etc/resolv.conf" || true
    fi
    if [[ ! -f "/etc/resolv.conf.bak" ]]; then
        cp -L /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    fi
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
}

# --- 3. 清理干扰 ---
clean_conflicts() {
    log "正在清理旧的 DNS 干扰..."
    # 屏蔽 Cloud-init
    if [[ -d "/etc/cloud" ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi
    # 屏蔽 DHCP
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo >> "$dhclient_conf"
            echo 'ignore domain-name-servers;' >> "$dhclient_conf"
            echo 'ignore domain-search;' >> "$dhclient_conf"
        fi
    fi
    # 等待 apt 锁
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 2
    done
    # 卸载 resolvconf
    if dpkg -s resolvconf &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y resolvconf > /dev/null
    fi
    if [[ -f "/etc/network/if-up.d/resolved" ]]; then
        chmod -x "/etc/network/if-up.d/resolved"
    fi
}

# --- 4. 部署 DNS ---
deploy_dns() {
    log "正在配置 Systemd-Resolved..."
    if ! command -v resolvectl &> /dev/null; then
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
    fi

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "${CONF_CONTENT}" > /etc/systemd/resolved.conf.d/99-hardening.conf
    
    systemctl unmask systemd-resolved >/dev/null 2>&1 || true
    systemctl enable systemd-resolved
    systemctl start systemd-resolved

    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    systemctl daemon-reload
    systemctl restart systemd-resolved
    resolvectl flush-caches || true
}

# --- 5. 验证 ---
verify() {
    echo -e "\n=== 最终验证 ==="
    local status
    status=$(LC_ALL=C resolvectl status)
    if echo "$status" | grep -qE "DNSOverTLS: yes|\+DNSOverTLS"; then
        echo -e "DoT 加密: ${GREEN}已开启${NC}"
    else
        echo -e "DoT 加密: ${RED}未开启${NC}"
    fi
    if echo "$status" | grep -q "8.8.8.8"; then
        echo -e "服务器:   ${GREEN}配置正确${NC}"
    else
        echo -e "服务器:   ${YELLOW}未匹配${NC}"
    fi
}

main() {
    check_env
    rescue_network
    clean_conflicts
    deploy_dns
    verify
}

main "$@"
