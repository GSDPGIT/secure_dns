#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: Linux DNS 极致净化与安全加固 (Systemd-Resolved + DoT) v3.0 (Pro Log版)
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

# --- 颜色与格式 ---
readonly GREEN="\033[0;32m"
readonly YELLOW="\033[1;33m"
readonly RED="\033[0;31m"
readonly BLUE="\033[0;34m"
readonly CYAN="\033[0;36m"
readonly NC="\033[0m"

# --- 增强日志函数 ---
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
check() { echo -e "${CYAN}[检测]${NC} $1"; }
fix()  { echo -e "${YELLOW}[执行]${NC} $1"; }
pass() { echo -e "${GREEN}[成功]${NC} $1"; }
fail() { echo -e "${RED}[错误]${NC} $1" >&2; }
banner() {
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${CYAN}   Linux DNS 极致净化与安全加固脚本 (Systemd-Resolved)    ${NC}"
    echo -e "${CYAN}==========================================================${NC}"
}

# --- 1. 环境与权限检测 ---
check_env() {
    echo -e "\n>>> 阶段 1/5: 环境预检"
    if [[ $EUID -ne 0 ]]; then
       fail "权限不足：请使用 sudo 或 root 身份运行。"
       exit 1
    fi
    pass "Root 权限已确认"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "当前系统: $PRETTY_NAME"
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
            fail "此脚本仅支持 Debian/Ubuntu 系统。"
            exit 1
        fi
    fi
    pass "操作系统兼容性检查通过"

    if ! command -v chattr &> /dev/null; then
        fix "未找到 chattr 工具，正在安装 e2fsprogs..."
        apt-get update -y && apt-get install -y e2fsprogs || true
    fi
}

# --- 2. 网络救援 ---
rescue_network() {
    echo -e "\n>>> 阶段 2/5: 网络连通性保障"
    check "正在测试网络连接 (Ping Google DNS)..."
    
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        pass "网络连接正常"
    else
        info "网络连接不畅，准备执行临时修复..."
        # 解锁并备份
        if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then
            fix "发现 /etc/resolv.conf 被锁定，正在解锁..."
            chattr -i "/etc/resolv.conf" || true
        fi
        
        if [[ ! -f "/etc/resolv.conf.bak" ]]; then
            cp -L /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            info "已备份原配置到 /etc/resolv.conf.bak"
        fi
        
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        pass "已注入救援 DNS (8.8.8.8)，确保依赖下载成功"
    fi
}

# --- 3. 清理干扰 ---
clean_conflicts() {
    echo -e "\n>>> 阶段 3/5: 清除 DNS 干扰源"
    
    # 3.1 Cloud-init
    check "检查 Cloud-init..."
    if [[ -d "/etc/cloud" ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        fix "已禁用 Cloud-init 网络接管 (防止重启还原)"
    else
        info "未检测到 Cloud-init，跳过"
    fi

    # 3.2 DHCP
    check "检查 DHCP 客户端配置..."
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo >> "$dhclient_conf"
            echo 'ignore domain-name-servers;' >> "$dhclient_conf"
            echo 'ignore domain-search;' >> "$dhclient_conf"
            fix "已修改 dhclient.conf (屏蔽运营商下发的 DNS)"
        else
            pass "dhclient.conf 已处于净化状态"
        fi
    else
        info "未找到 dhclient 配置文件，跳过"
    fi

    # 3.3 Resolvconf
    check "检查 resolvconf 冲突包..."
    if dpkg -s resolvconf &> /dev/null; then
        # 等待锁
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            info "等待 apt 锁释放..."
            sleep 2
        done
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y resolvconf > /dev/null
        fix "已卸载冲突软件: resolvconf"
    else
        pass "未安装 resolvconf，无冲突"
    fi

    # 3.4 if-up 脚本
    if [[ -f "/etc/network/if-up.d/resolved" ]]; then
        chmod -x "/etc/network/if-up.d/resolved"
        fix "已禁用 if-up.d/resolved 脚本"
    fi
}

# --- 4. 部署 DNS ---
deploy_dns() {
    echo -e "\n>>> 阶段 4/5: 部署 Systemd-Resolved (DoT)"
    
    check "检查 systemd-resolved 安装状态..."
    if ! command -v resolvectl &> /dev/null; then
        fix "正在安装 systemd-resolved..."
        apt-get update -y > /dev/null
        apt-get install -y systemd-resolved > /dev/null
    else
        pass "systemd-resolved 已安装"
    fi

    fix "写入安全配置文件 (Drop-in模式)..."
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "${CONF_CONTENT}" > /etc/systemd/resolved.conf.d/99-hardening.conf
    
    fix "重置并重启服务..."
    systemctl unmask systemd-resolved >/dev/null 2>&1 || true
    systemctl enable systemd-resolved >/dev/null 2>&1
    systemctl start systemd-resolved

    check "接管 /etc/resolv.conf..."
    # 再次确保解锁
    if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then chattr -i "/etc/resolv.conf"; fi
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    if [[ -L "/etc/resolv.conf" ]]; then
        pass "软链接建立成功 (/etc/resolv.conf -> stub-resolv.conf)"
    else
        fail "软链接建立失败！"
        exit 1
    fi

    systemctl daemon-reload
    systemctl restart systemd-resolved
    resolvectl flush-caches || true
    pass "服务重启完成，缓存已刷新"
}

# --- 5. 验证 ---
verify() {
    echo -e "\n>>> 阶段 5/5: 最终状态验证"
    echo -e "----------------------------------------------------------"
    
    local status
    status=$(LC_ALL=C resolvectl status)
    
    # 1. DoT 检查
    if echo "$status" | grep -qE "DNSOverTLS: yes|\+DNSOverTLS"; then
        echo -e "加密协议 (DoT)    : ${GREEN}● 已开启 (安全)${NC}"
    else
        echo -e "加密协议 (DoT)    : ${RED}○ 未开启 (危险)${NC}"
    fi

    # 2. DNS 服务器检查
    if echo "$status" | grep -q "8.8.8.8"; then
        echo -e "上游 DNS 服务器   : ${GREEN}● Google/Cloudflare (正确)${NC}"
    else
        echo -e "上游 DNS 服务器   : ${YELLOW}○ 未匹配 (需检查)${NC}"
    fi
    
    # 3. 文件锁定逻辑说明
    if [[ -L "/etc/resolv.conf" ]]; then
         echo -e "文件接管模式      : ${GREEN}● Symlink 软链接 (推荐)${NC}"
    fi

    echo -e "----------------------------------------------------------"
    echo -e "${GREEN}🎉 恭喜！系统 DNS 已成功加固。${NC}"
    echo -e "防篡改机制已生效：Cloud-init被禁用，DHCP配置已屏蔽。"
}

main() {
    banner
    check_env
    rescue_network
    clean_conflicts
    deploy_dns
    verify
}

main "$@"
