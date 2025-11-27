#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: Linux DNS 极致净化与安全加固 (Systemd-Resolved + DoT) v4.0 (交互菜单版)
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

# --- 日志工具 ---
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
check() { echo -e "${CYAN}[检测]${NC} $1"; }
fix()  { echo -e "${YELLOW}[执行]${NC} $1"; }
pass() { echo -e "${GREEN}[成功]${NC} $1"; }
fail() { echo -e "${RED}[错误]${NC} $1" >&2; }

# ======================= 功能模块 =======================

# --- 1. 环境与权限检测 ---
check_env() {
    echo -e "\n>>> 阶段 1/5: 环境预检"
    if [[ $EUID -ne 0 ]]; then
       fail "权限不足：请使用 sudo 或 root 身份运行。"
       exit 1
    fi
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
            fail "此脚本仅支持 Debian/Ubuntu 系统。"
            exit 1
        fi
    fi
    if ! command -v chattr &> /dev/null; then
        fix "未找到 chattr 工具，正在安装 e2fsprogs..."
        apt-get update -y && apt-get install -y e2fsprogs || true
    fi
    pass "环境检查通过"
}

# --- 2. 网络救援 ---
rescue_network() {
    echo -e "\n>>> 阶段 2/5: 网络连通性保障"
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        pass "网络连接正常"
    else
        info "网络连接不畅，注入救援 DNS..."
        if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then chattr -i "/etc/resolv.conf" || true; fi
        if [[ ! -f "/etc/resolv.conf.bak" ]]; then cp -L /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true; fi
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        pass "救援 DNS 已注入"
    fi
}

# --- 3. 清理干扰 ---
clean_conflicts() {
    echo -e "\n>>> 阶段 3/5: 清除 DNS 干扰源"
    
    # Cloud-init
    if [[ -d "/etc/cloud" ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        fix "已禁用 Cloud-init 网络接管"
    else
        info "Cloud-init 未检测到，跳过"
    fi

    # DHCP
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]]; then
        if ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
            echo >> "$dhclient_conf"
            echo 'ignore domain-name-servers;' >> "$dhclient_conf"
            echo 'ignore domain-search;' >> "$dhclient_conf"
            fix "已修改 dhclient.conf (屏蔽 DHCP DNS)"
        fi
    fi

    # Resolvconf
    if dpkg -s resolvconf &> /dev/null; then
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y resolvconf > /dev/null
        fix "已卸载 resolvconf"
    fi

    # if-up
    if [[ -f "/etc/network/if-up.d/resolved" ]]; then
        chmod -x "/etc/network/if-up.d/resolved"
        fix "已禁用 if-up 脚本"
    fi
}

# --- 4. 部署 DNS ---
deploy_dns() {
    echo -e "\n>>> 阶段 4/5: 部署 Systemd-Resolved (DoT)"
    
    if ! command -v resolvectl &> /dev/null; then
        fix "安装 systemd-resolved..."
        apt-get update -y > /dev/null && apt-get install -y systemd-resolved > /dev/null
    fi

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "${CONF_CONTENT}" > /etc/systemd/resolved.conf.d/99-hardening.conf
    
    systemctl unmask systemd-resolved >/dev/null 2>&1 || true
    systemctl enable systemd-resolved >/dev/null 2>&1
    systemctl start systemd-resolved

    if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then chattr -i "/etc/resolv.conf"; fi
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    systemctl daemon-reload
    systemctl restart systemd-resolved
    resolvectl flush-caches || true
    pass "服务部署完成"
}

# --- 5. 深度验证 (Dashboard) ---
run_verification() {
    echo -e "\n========================================================"
    echo -e "           DNS 安全与健康深度检测报告            "
    echo -e "========================================================"
    
    local score=0
    local total=5
    
    # 1. 检查服务状态
    if systemctl is-active --quiet systemd-resolved; then
        echo -e " [1] 服务状态      : ${GREEN}● 运行中 (Active)${NC}"
        ((score++))
    else
        echo -e " [1] 服务状态      : ${RED}✖ 未运行${NC}"
    fi

    # 2. 检查 resolv.conf 链接
    if [[ -L "/etc/resolv.conf" ]] && ls -l /etc/resolv.conf | grep -q "stub-resolv.conf"; then
        echo -e " [2] 文件接管      : ${GREEN}● 正确 (Stub-Resolv Link)${NC}"
        ((score++))
    else
        echo -e " [2] 文件接管      : ${RED}✖ 错误 (未正确链接)${NC}"
    fi

    # 获取 resolvectl 状态
    local status_output
    status_output=$(LC_ALL=C resolvectl status 2>/dev/null || echo "")

    # 3. 检查 DoT 状态
    if echo "$status_output" | grep -qE "DNSOverTLS: yes|\+DNSOverTLS"; then
        echo -e " [3] 加密传输(DoT) : ${GREEN}● 已开启 (Encrypted)${NC}"
        ((score++))
    else
        echo -e " [3] 加密传输(DoT) : ${YELLOW}▲ 未开启 (Plain Text)${NC}"
    fi

    # 4. 检查上游服务器
    if echo "$status_output" | grep -q "8.8.8.8" && echo "$status_output" | grep -q "1.1.1.1"; then
        echo -e " [4] 上游服务器    : ${GREEN}● Google/Cloudflare${NC}"
        ((score++))
    else
        echo -e " [4] 上游服务器    : ${YELLOW}▲ 未匹配目标配置${NC}"
    fi

    # 5. 防篡改检查 (Cloud-init & DHCP)
    local anti_tamper=true
    if [[ -d "/etc/cloud" ]] && [[ ! -f "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" ]]; then anti_tamper=false; fi
    if [[ -f "/etc/dhcp/dhclient.conf" ]] && ! grep -q "ignore domain-name-servers" "/etc/dhcp/dhclient.conf"; then anti_tamper=false; fi
    
    if [[ "$anti_tamper" == true ]]; then
        echo -e " [5] 防篡改机制    : ${GREEN}● 已部署 (Cloud-init/DHCP Blocked)${NC}"
        ((score++))
    else
        echo -e " [5] 防篡改机制    : ${YELLOW}▲ 不完整 (重启可能失效)${NC}"
    fi

    # 6. 真实解析测试
    echo -e "--------------------------------------------------------"
    local resolve_time
    # 尝试解析 google.com
    if ping -c 1 -W 2 google.com &> /dev/null; then
         echo -e " [6] 真实解析测试  : ${GREEN}● 通畅 (google.com)${NC}"
    else
         echo -e " [6] 真实解析测试  : ${RED}✖ 失败 (无法解析域名)${NC}"
    fi
    echo -e "========================================================"
    
    if [[ $score -eq $total ]]; then
        echo -e " 综合评价: ${GREEN}完美 (100%)${NC} - 您的 DNS 环境非常安全且坚固。"
    else
        echo -e " 综合评价: ${YELLOW}待优化${NC} - 建议重新运行 '安装/修复' 选项。"
    fi
    echo -e "========================================================"
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}#############################################################${NC}"
    echo -e "${CYAN}#     Linux DNS 极致净化与安全加固脚本 (v4.0 菜单版)        #${NC}"
    echo -e "${CYAN}#     功能: DoT 加密 | 防劫持 | 防重启还原 | 深度检测         #${NC}"
    echo -e "${CYAN}#############################################################${NC}"
    echo -e ""
    echo -e "  ${GREEN}[1]${NC} 开始安装 / 修复 DNS 环境 (推荐)"
    echo -e "  ${GREEN}[2]${NC} 深度系统检测 (查看当前状态)"
    echo -e "  ${GREEN}[0]${NC} 退出脚本"
    echo -e ""
    echo -n " 请输入数字 [0-2]: "
}

main() {
    # 强制 LC_ALL 以便 grep
    export LC_ALL=C
    
    while true; do
        show_menu
        read -r choice
        case $choice in
            1)
                check_env
                rescue_network
                clean_conflicts
                deploy_dns
                run_verification
                echo -e "\n按回车键返回菜单..."
                read -r
                ;;
            2)
                run_verification
                echo -e "\n按回车键返回菜单..."
                read -r
                ;;
            0)
                echo -e "\n退出脚本。再见！"
                exit 0
                ;;
            *)
                echo -e "\n${RED}无效输入，请重试。${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
