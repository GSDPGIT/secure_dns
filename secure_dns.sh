#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: Linux DNS 极致净化与安全加固 (v4.1 修复版)
# 更新日志: 修复检测崩溃问题，优化UI对齐
# ==============================================================================

# 关闭 pipefail 防止检测逻辑误触退出，保留 -u (未定义变量报错)
set -u

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
fix()  { echo -e "${YELLOW}[执行]${NC} $1"; }
pass() { echo -e "${GREEN}[成功]${NC} $1"; }
fail() { echo -e "${RED}[错误]${NC} $1" >&2; }

# --- 1. 环境预检 ---
check_env() {
    if [[ $EUID -ne 0 ]]; then fail "权限不足：请使用 sudo 或 root 身份运行。"; exit 1; fi
    if ! command -v chattr &> /dev/null; then
        fix "安装必要工具 chattr..."
        apt-get update -y >/dev/null && apt-get install -y e2fsprogs >/dev/null || true
    fi
}

# --- 2. 网络救援 ---
rescue_network() {
    echo -e "\n>>> 正在检查网络连通性..."
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        pass "网络连接正常"
    else
        info "网络微调中..."
        if lsattr "/etc/resolv.conf" 2>/dev/null | grep -q "i"; then chattr -i "/etc/resolv.conf" || true; fi
        if [[ ! -f "/etc/resolv.conf.bak" ]]; then cp -L /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true; fi
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        pass "救援 DNS 已注入"
    fi
}

# --- 3. 清理干扰 ---
clean_conflicts() {
    echo -e "\n>>> 正在清理 DNS 干扰源..."
    # Cloud-init
    if [[ -d "/etc/cloud" ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        fix "已禁用 Cloud-init"
    fi
    # DHCP
    local dhclient_conf="/etc/dhcp/dhclient.conf"
    if [[ -f "$dhclient_conf" ]] && ! grep -q "ignore domain-name-servers;" "$dhclient_conf"; then
        echo -e "\nignore domain-name-servers;\nignore domain-search;" >> "$dhclient_conf"
        fix "已屏蔽 DHCP DNS"
    fi
    # Resolvconf
    if dpkg -s resolvconf &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get remove -y resolvconf > /dev/null
        fix "已卸载 resolvconf"
    fi
    # if-up
    if [[ -f "/etc/network/if-up.d/resolved" ]]; then chmod -x "/etc/network/if-up.d/resolved"; fi
}

# --- 4. 部署 DNS ---
deploy_dns() {
    echo -e "\n>>> 正在部署 Systemd-Resolved (DoT)..."
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

# --- 5. 深度验证 (优化排版版) ---
run_verification() {
    echo -e "\n=========================================================="
    echo -e "           DNS 安全与健康深度检测报告            "
    echo -e "=========================================================="
    
    local score=0
    
    # 定义打印格式：%-18s 表示左对齐占18字符
    print_status() {
        local name="$1"
        local result="$2"
        local info="$3"
        printf " %-18s : %b %s${NC}\n" "$name" "$result" "$info"
    }

    # 1. 服务状态
    if systemctl is-active --quiet systemd-resolved; then
        print_status "服务状态(Systemd)" "${GREEN}●" "运行中 (Active)"
        ((score++))
    else
        print_status "服务状态(Systemd)" "${RED}✖" "未运行"
    fi

    # 2. 文件接管
    if [[ -L "/etc/resolv.conf" ]] && readlink "/etc/resolv.conf" | grep -q "stub-resolv.conf"; then
        print_status "文件接管(Symlink)" "${GREEN}●" "正确"
        ((score++))
    else
        print_status "文件接管(Symlink)" "${RED}✖" "错误 (未链接到stub)"
    fi

    # 获取状态文本
    local status_output
    status_output=$(LC_ALL=C resolvectl status 2>/dev/null || echo "")

    # 3. 加密传输
    if echo "$status_output" | grep -qE "DNSOverTLS: yes|\+DNSOverTLS"; then
        print_status "加密传输(DoT)" "${GREEN}●" "已开启 (Encrypted)"
        ((score++))
    else
        print_status "加密传输(DoT)" "${YELLOW}▲" "未开启"
    fi

    # 4. 上游服务器
    if echo "$status_output" | grep -q "8.8.8.8" && echo "$status_output" | grep -q "1.1.1.1"; then
        print_status "上游服务器" "${GREEN}●" "Google/Cloudflare"
        ((score++))
    else
        print_status "上游服务器" "${YELLOW}▲" "未匹配"
    fi

    # 5. 防篡改
    local anti_tamper=true
    if [[ -d "/etc/cloud" ]] && [[ ! -f "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" ]]; then anti_tamper=false; fi
    if [[ -f "/etc/dhcp/dhclient.conf" ]] && ! grep -q "ignore domain-name-servers" "/etc/dhcp/dhclient.conf"; then anti_tamper=false; fi
    
    if [[ "$anti_tamper" == true ]]; then
        print_status "防篡改机制" "${GREEN}●" "已部署"
        ((score++))
    else
        print_status "防篡改机制" "${YELLOW}▲" "不完整"
    fi

    echo -e "----------------------------------------------------------"
    # 6. 解析测试
    local start_time=$(date +%s%N)
    if ping -c 1 -W 2 google.com &> /dev/null; then
        local end_time=$(date +%s%N)
        local duration=$(( (end_time - start_time) / 1000000 ))
        print_status "真实解析测试" "${GREEN}●" "通畅 (耗时: ${duration}ms)"
        ((score++))
    else
        print_status "真实解析测试" "${RED}✖" "失败 (无法解析)"
    fi
    echo -e "=========================================================="
    
    if [[ $score -ge 5 ]]; then
        echo -e " 综合评价: ${GREEN}完美 (Safe)${NC} - 系统 DNS 环境非常坚固。"
    else
        echo -e " 综合评价: ${YELLOW}待优化${NC} - 请尝试运行 [1] 进行修复。"
    fi
    echo -e "=========================================================="
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}#############################################################${NC}"
    echo -e "${CYAN}#     Linux DNS 极致净化与安全加固脚本 (v4.1 修复版)        #${NC}"
    echo -e "${CYAN}#############################################################${NC}"
    echo -e ""
    echo -e "  ${GREEN}[1]${NC} 一键安装 / 修复 (推荐)"
    echo -e "  ${GREEN}[2]${NC} 深度系统检测"
    echo -e "  ${GREEN}[0]${NC} 退出"
    echo -e ""
    echo -n " 请输入数字 [0-2]: "
}

main() {
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
                echo -e "\n按回车键返回..."
                read -r
                ;;
            2)
                run_verification
                echo -e "\n按回车键返回..."
                read -r
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "\n输入错误。"
                sleep 1
                ;;
        esac
    done
}

main "$@"
