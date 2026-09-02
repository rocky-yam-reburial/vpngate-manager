# VPNGate Supernode Manager 🛡️

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Python 3](https://img.shields.io/badge/Python-3.x-green.svg)](https://python.org)

这是一个专为 Linux VPS 打造的 **VPN Gate 智能出口管理框架**。针对传统公共 VPN 节点高延迟、易断连、易封锁的痛点，本项目深度整合了并发端口测速、策略路由防死锁、地理/ASN 数据清洗与 Telegram 远程交互，将免费志愿节点转化为高可用、高纯净度的出口网络。

## 🌟 核心特性

* **🚀 真实应用层探针 (Real TCPing)**：摒弃官方虚假 ICMP 延迟数据。利用 Python 并发线程池，秒级完成全量节点的 TCP 端口真实握手测速。
* **🛡️ 策略路由防死锁 (Anti-Deadlock Routing)**：向系统底层注入 `iproute2` 策略路由规则 (Table 200)，彻底解决连接 VPN 后 VPS 本机失联、守护进程断网死锁的致命缺陷。
* **🧹 区域与 ASN 精准清洗 (Geo & ASN Filtering)**：集成异步 IP-API 分块查询，穿透显示节点真实的地理位置 (Region/City) 与运营商 (ISP)。支持一键过滤拥挤的官方/学术节点。
* **🤖 Telegram 双层交互菜单 (Interactive Bot)**：无需 SSH 登录，通过 Telegram 机器人实现全天候跨端管理。支持一键智能拨号、全量节点查表、指定节点拨号及巡检周期动态调节。
* **⏱️ 后台不死守护 (Daemon Auto-Heal)**：基于 `systemd` 托管的守护进程，秒级感知网络状态与出站 IP 异常，自动熔断死链并无缝拉起新的最优节点。

## ⚙️ 一键部署指南

**系统要求:** Debian / Ubuntu / CentOS / Alpine (需 Root 权限)

# 下载并运行部署脚本

wget -O install.sh https://raw.githubusercontent.com/rocky-yam-reburial/vpngate-manager/main/install.sh && bash install.sh
