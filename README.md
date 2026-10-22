# VPNGate Supernode Manager 🛡️ (v1.0 最终版)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python: 3.x](https://img.shields.io/badge/Python-3.x-blue.svg)](https://www.python.org/)

专为 Linux VPS 与 NAT/LXC 容器打造的企业级 VPN Gate 智能出口管理框架。针对传统公有 VPN 高延迟、假死断流、风控标黑及断网失联等痛点，提供「开机自愈保活 + 人工原生 IP 风控评级」的双模控制系统。

---

## 🌟 核心特性

* **🛡️ S/A/B/C 原生风控体检评级**
  * 拒绝粗糙的文本关键词匹配，直读 **IPQS (`connection_type`)**、**IPinfo (`asn.type`)** 与 **ip-api (`hosting`)** 原生类型字段，精准识别原生家庭住宅宽带（Residential）与机房（Data Center）。
  * 并发反查 **5 大国际反滥用黑名单（Spamhaus ZEN / Barracuda / DroneBL / SpamCop / SORBS）**。
  * 结合 **AbuseIPDB 涉案举报历史** 与 **IPQS 商业欺诈分**，输出绿色 S 级（绝品住宅）、蓝色 A 级（优质中继）、黄色 B 级（及格）与红色 C 级（高危劣质）动态评级。

* **⚡ 智能双模分离架构**
  * **自动通道（后台保活）**：零交互、零 API 消耗。系统开机或网络断流瞬间，0 秒等待直接按全网并发 TCPing 延迟秒连可用出口，保障网络可用性。
  * **人工通道（交互决策）**：通过控制面板选定节点时，可按需即时调用风控雷达，人工择优挑选原生家宽。

* **🔄 双重看门狗守护自愈 (Watchdog)**
  * **第一重（Systemd / OpenRC 进程锁）**：进程级异常崩溃 3 秒内原地拉起。
  * **第二重（Crontab 独立哨兵）**：系统底层每分钟巡检，即便守护进程被外部意外强杀，亦能自动复活。

* **🌐 双重防断网路由隔离 (Anti-Deadlock Routing)**
  * 采用 `iptables CONNMARK` 连接追踪标记与 `ip rule (table 200)` 双保险，回程流量原路返回，彻底根除更改默认网关导致 SSH 离线的风险。

* **🔒 纯 IPv4 固化与 DNS 物理锁死**
  * 彻底冲刷物理网卡残留 IPv6 地址，消除路由泄漏；硬编码公共安全 DNS（1.1.1.1 / 8.8.8.8）并执行系统只读锁定，切断内网 DNS 劫持。

---

## ⚙️ 一键极速部署

### 系统要求
* **操作系统**：Debian / Ubuntu / CentOS / Alpine Linux
* **运行权限**：Root 权限
* **虚拟化要求**：VPS 需支持并开启 TUN/TAP 模块

### 部署命令
> **提示**：安装流程包含交互式 API 凭据配置，请直接复制完整单行命令（将命令中的 `YOUR_GITHUB_USERNAME` 替换为你的真实 GitHub 用户名）：

```bash
wget -qO /tmp/install.sh [https://raw.githubusercontent.com/rocky-yam-reburial/vpngate-manager/main/install.sh](https://raw.githubusercontent.com/rocky-yam-reburial/vpngate-manager/main/install.sh) && bash /tmp/install.sh && rm -f /tmp/install.sh

🎮 控制面板功能指南
部署完成后，在任意终端输入以下命令启动交互控制台：

Bash
vpngate
菜单选项详解
1. 自动智能拨号

执行全量节点并发测速，跳过繁琐体检，毫秒级快速接入延迟最低的最佳出口，适合应急快速通网。

2. 手动选择节点

展示当前目标国家的节点明细（含 Ping 值、带宽、物理城市与真实 ASN）。选定节点后，可选择是否进行 S/A/B/C 评级体检，供人工挑选优质住宅出口。

3. 停止连接

立即断开 OpenVPN 隧道，冲刷路由并安全恢复 VPS 本地物理网络出口，同时挂起后台看门狗（防止系统反复重新拨号）。

4. 查看当前网络真实状态

实时回显出站 IP、所在地理位置及真实运营商 ASN 广播归属，确认当前流量是否处于代理保护中。

5. 系统与设置

包含多项核心运维开关：

切换目标国家代号（如 JP、US、HK）

开关后台双重看门狗与开机自愈

开关官方/学术拥挤节点过滤

修改守护巡检周期频率

配置或更新 AbuseIPDB、IPQS 与 IPinfo API 密钥

一键自检与重拉守护服务

6. 🛡️ IP 专业风控与滥用黑名单体检

针对当前出口 IP 执行全维度诊断：包含 5 大国际反滥用黑名单（Spamhaus、Barracuda、DroneBL、SpamCop、SORBS）反查、AbuseIPDB 90 天涉案举报次数、IPQS 欺诈风险值以及原生 Residential/Data Center 属性认定。

0. 退出面板

安全关闭控制界面，后台守护服务与 VPN 隧道保持正常运行。

📄 开源许可证
本项目基于 MIT License 协议开源。
