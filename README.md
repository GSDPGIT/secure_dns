# 🛡️ Linux DNS 极致净化与安全加固脚本 (DoT Edition)

> **强制接管 VPS 的 DNS 解析权，开启 DNS-over-TLS (DoT) 加密传输，彻底防止 DNS 劫持与泄露。**

[![Linux](https://img.shields.io/badge/Linux-Debian%20%7C%20Ubuntu-blue?logo=linux)](https://github.com/GSDPGIT/secure_dns)
[![Bash](https://img.shields.io/badge/Language-Bash-green?logo=gnu-bash)](https://github.com/GSDPGIT/secure_dns)
[![License](https://img.shields.io/badge/License-MIT-orange)](https://github.com/GSDPGIT/secure_dns)

## 📖 简介

在许多海外 VPS 环境中，服务商提供的默认 DNS 通常存在以下问题：
* **不安全**：使用明文 UDP 传输，容易被中间人监听或篡改。
* **不可控**：重启服务器后，`/etc/resolv.conf` 经常被 Cloud-init 或 DHCP 强制重置。
* **隐私泄露**：上游 DNS 可能会记录你的访问日志。

本脚本专为 **Debian/Ubuntu** 系统设计，采用“强制接管”策略，通过 `systemd-resolved` 实现 **DNS-over-TLS (DoT)** 加密查询，并屏蔽 Cloud-init 和 DHCP 的干扰，确保你的 DNS 配置**重启不失效**。

## 🚀 核心功能

* **🔒 顶级安全 (DoT)**：强制开启 DNS-over-TLS，使用 Google (8.8.8.8) 和 Cloudflare (1.1.1.1) 的加密端口 (853) 进行查询。
* **🛡️ 防重启还原**：自动检测并屏蔽 `cloud-init` 的网络接管功能，修改 `dhclient` 配置，防止重启后 DNS 被 ISP 覆盖。
* **📊 深度检测仪表盘**：内置交互式菜单，可一键进行系统 DNS 健康度深度扫描（服务状态、加密验证、真实解析测试）。
* **🚑 网络救援模式**：脚本运行前会自动检测网络。如果当前 DNS 已损坏，会临时注入救援 DNS，确保依赖包能正常下载。

## 💻 快速开始

### 系统要求
* **OS**: Debian 10/11/12 或 Ubuntu 20.04/22.04/24.04
* **User**: Root 用户或具有 Sudo 权限

### 一键安装脚本 (交互菜单版)

请直接复制下方命令运行：

```bash
curl -sL https://raw.githubusercontent.com/GSDPGIT/secure_dns/main/secure_dns.sh | tr -d '\r' > secure_dns.sh && chmod +x secure_dns.sh && bash secure_dns.sh
