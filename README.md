Markdown


# VPNGate Supernode Manager 🛡️

专为 Linux VPS 打造的 **VPN Gate 智能出口管理框架**。整合真实连接测速、策略路由防断网、ASN 级清洗与 Telegram 远程交互。

## 核心特性

* **真实探针 (Real TCPing)**：秒级并发探测 TCP 端口握手延迟，剔除虚假官方数据。
* **策略路由防死锁**：注入底层策略路由 (Table 200)，避免全局出网导致 SSH 失联或死链无法重拉配置。
* **ASN 与地区解析**：展示实际地理位置 (Region/City) 与运营商 (ISP)，支持屏蔽官方/学术拥挤节点。
* **Telegram 深度融合**：双层按键交互菜单，支持手动选点、切换国家及远程调控。
* **后台守护进程**：掉线或出口 IP 异常时自动熔断并重选最优节点。

## 快速安装

bash
wget -O install.sh <你的RAW链接> && bash install.sh



部署完成后，终端输入 `vpngate` 即可呼出管理面板。
