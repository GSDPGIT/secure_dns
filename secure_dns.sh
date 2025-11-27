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

# --- 颜色输出 ---
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly BLUE="\033[0;34m"
readonly NC="\033[0m"

# --- 日志函数 ---
log() { echo -e "${GREEN}--> $1${NC}"; }
log_info() { echo -e "${BLUE}[信息] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[注意] $1${NC}"; }
log_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

# --- 1. 环境与权限检测 ---
check_env() {
    export LC_ALL=C
    if [[ $EUID -ne 0 ]]; then
       log_error "权限不足：请使用 sudo 或 root 身份运行此脚本。"
       exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
            log_error "系统不支持：此脚本专为 Debian/Ubuntu 设计。"
            exit 1
        fi
    else
        log_error "无法检测操作系统版本。"
        exit 1
    fi
    
    if ! command -v chattr &> /dev/null; then
        log_warn "未找到 chattr 命令，尝试安装..."
        apt-get update -y && apt-get install -y e2fsprogs || true
    fi
}

# --- 2. 网络救援 (保证 apt 可用) ---
rescue_network() {
    log "正在检查网络连通性..."
    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        log_warn "网络连接似乎不通畅，无需担心，正在尝试临时修复..."
    fi
    
    if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then
        chattr -i "/etc/resolv.conf" || true
    fi
    
    if [[ ! -f "/etc/resolv.conf.bak" ]]; then
        cp -L /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        log_info "原 /etc/resolv.conf 已备份为 .bak"
    fi
    
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    log "${GREEN}✅ 已临时注入救援 DNS (8.8.8.8)，准备下载依赖。${NC}"
}

# --- 3. 屏蔽 Cloud-init ---
disable_cloud_init() {
    if [[ -d "/etc/cloud" ]]; then
        log "正在配置 Cloud-init 禁止接管网络..."
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        log "${GREEN}✅ Cloud-init 网络配置已禁用 (防重启还原)。${NC}"
    fi
}

# --- 4. 清理干扰源 ---
clean_conflicts() {
    log "正在清理旧的 DNS 干扰..."

    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo >> "$dhclient_conf"
            echo 'ignore domain-name-servers;' >> "$dhclient_conf"
            echo 'ignore domain-search;' >> "$dhclient_conf"
            log "${GREEN}✅ 已屏蔽 DHCP 下发的 DNS。${NC}"
        fi
    fi

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log_warn "等待 apt 锁释放 (后台可能正在自动更新)..."
        sleep 2
    done

    if dpkg -s resolvconf &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y resolvconf > /dev/null
        log "${GREEN}✅ 已卸载 resolvconf。${NC}"
    fi
    
    if [[ -f "/etc/network/if-up.d/resolved" ]]; then
        chmod -x "/etc/network/if-up.d/resolved"
    fi
}

# --- 5. 部署 Systemd-Resolved ---
deploy_dns() {
    log "正在配置 Systemd-Resolved (DoT)..."

    if ! command -v resolvectl &> /dev/null; then
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
    fi

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "${CONF_CONTENT}" > /etc/systemd/resolved.conf.d/99-hardening.conf
    
    systemctl unmask systemd-resolved >/dev/null 2>&1 || true
    systemctl enable systemd-resolved
    systemctl start systemd-resolved

    log "正在建立软链接..."
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    if [[ -L "/etc/resolv.conf" ]]; then
        log "${GREEN}✅ DNS 解析权已成功接管。${NC}"
    else
        log_error "接管失败，无法创建软链接。"
        exit 1
    fi

    systemctl daemon-reload
    systemctl restart systemd-resolved
    resolvectl flush-caches || true
}

# --- 6. 最终状态验证 ---
verify() {
    echo -e "\n================ [ 最终状态验证 ] ================"
    local status
    status=$(LC_ALL=C resolvectl status)
    local pass=true

    if echo "$status" | grep -qE "DNSOverTLS: yes|\+DNSOverTLS"; then
        echo -e "DNS 加密 (DoT):  ${GREEN}[已开启]${NC}"
    else
        echo -e "DNS 加密 (DoT):  ${RED}[未开启]${NC}"
        pass=false
    fi

    if echo "$status" | grep -q "8.8.8.8"; then
        echo -e "DNS 服务器:      ${GREEN}[配置正确]${NC} (Google/Cloudflare)"
    else
        echo -e "DNS 服务器:      ${YELLOW}[未匹配]${NC}"
        pass=false
    fi
    
    echo "=================================================="
    if [[ "$pass" == true ]]; then
        echo -e "${GREEN}🎉 完美！脚本执行成功。DNS 已加固，防重启失效已部署。${NC}"
    else
        echo -e "${RED}❌ 警告: 部分检查未通过，请检查上方日志。${NC}"
    fi
}

main() {
    echo -e "\n>>> 开始执行 DNS 一键加固脚本 (v2.0)..."
    check_env
    rescue_network
    disable_cloud_init
    clean_conflicts
    deploy_dns
    verify
}

main "$@"
