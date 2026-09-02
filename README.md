# VPNGate Supernode Manager 🛡️

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Python 3](https://img.shields.io/badge/Python-3.x-green.svg)](https://python.org)

专为 Linux VPS 与 NAT LXC 容器打造的 **VPN Gate 智能出口管理框架**。针对传统公共 VPN 节点高延迟、易断连、易封锁的痛点，本项目深度整合了并发端口测速、跨平台防死锁路由、地理/ASN 数据清洗与 Telegram 远程交互。

## 🌟 核心特性

* **🚀 真实应用层探针 (Real TCPing)**：摒弃官方虚假 ICMP 延迟数据。利用 Python 并发线程池，秒级完成全量节点的 TCP 端口真实握手测速与标称带宽展示。
* **🛡️ 动态路由镜像防失联 (Anti-Deadlock Routing)**：通过精准镜像本机非 VPN 原生路由至 Table 200，完美适配无网关的 NAT/BGP 复杂网络架构，彻底告别拨号瞬间 SSH 失联的梦魇。
* **⚙️ 双核守护自适应 (Systemd & OpenRC)**：原生适配 Debian/Ubuntu/CentOS 等主流系统，并深度兼容追求极致轻量的 Alpine Linux。
* **🧹 区域与 ASN 精准清洗 (Geo & ASN Filtering)**：集成异步 IP-API 分块查询，穿透显示节点真实的地理位置 (Region/City) 与底层运营商 (ISP)，一键过滤拥挤学术节点。
* **🤖 Telegram 双层交互菜单 (Interactive Bot)**：无需 SSH 登录，通过 Telegram 实现全天候跨端管理。支持一键智能拨号、手动选点及巡检周期动态调节。

## ⚙️ 一键部署指南

**系统要求:** Debian / Ubuntu / CentOS / Alpine (需 Root 权限及 TUN/TAP 模块支持)

```bash
wget -O install.sh [https://raw.githubusercontent.com/rocky-yam-reburial/vpngate-manager/main/install.sh](https://raw.githubusercontent.com/rocky-yam-reburial/vpngate-manager/main/install.sh) && bash install.sh
