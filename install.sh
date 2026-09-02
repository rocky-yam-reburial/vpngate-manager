---

**终极版 install.sh 代码**

```bash
#!/usr/bin/env bash
set -e

echo "======================================================="
echo "  VPN Gate 终极版 (Systemd/OpenRC自适应 + 路由镜像)"
echo "======================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[!] 请使用 root 权限运行此脚本"
    exit 1
fi

echo "[*] 1/7 进行 TUN/TAP 硬件环境校验..."
if [ ! -c /dev/net/tun ]; then
    echo "[!] 致命错误: TUN/TAP 模块未开启 (/dev/net/tun 不存在)。"
    echo "    请前往 VPS/LXC 服务商控制面板开启 TUN/TAP 支持，并重启机器后重试。"
    exit 1
fi

echo "[*] 2/7 安装系统依赖包 (自适应 Alpine/Debian/RedHat)..."
if [ -f /etc/alpine-release ]; then
    apk update > /dev/null
    apk add bash curl python3 openvpn iproute2 procps > /dev/null
elif [ -f /etc/debian_version ]; then
    apt-get update -y > /dev/null
    apt-get install -y curl python3 openvpn iproute2 procps > /dev/null
elif [ -f /etc/redhat-release ]; then
    yum install -y curl python3 openvpn iproute procps-ng > /dev/null
fi

echo "[*] 3/7 探测 Init 系统守护进程..."
if command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
    echo "[-] 识别到 Systemd (Debian/Ubuntu/CentOS)"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
    echo "[-] 识别到 OpenRC (Alpine Linux)"
else
    echo "[!] 未知守护进程系统，安装中止。"
    exit 1
fi

echo "[*] 4/7 初始化基线 IP 配置与禁用 IPv6..."
LOCAL_IP=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
PUBLIC_IP=$(curl -s --max-time 5 http://ip-api.com/json | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP=$LOCAL_IP; fi

mkdir -p /etc/vpngate
echo "$PUBLIC_IP" > /etc/vpngate/main_ip.txt

MAIN_DEV=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
if [ -n "$MAIN_DEV" ]; then
    sysctl -w net.ipv6.conf.$MAIN_DEV.disable_ipv6=1 >/dev/null 2>&1 || true
fi
cat << EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

echo "[*] 5/7 注入「原生路由镜像克隆」防断网核心..."
cat << 'EOF' > /usr/local/bin/vps-inbound-protect.sh
#!/usr/bin/env bash
LOCAL_IP=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
MAIN_DEV=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
if [ -n "$MAIN_DEV" ]; then sysctl -w net.ipv4.conf.$MAIN_DEV.rp_filter=0 >/dev/null 2>&1 || true; fi
ip rule del from $LOCAL_IP table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true
ip -4 route show table main | grep -E -v 'tun|vpn|ppp' | while read -r route; do
    ip route add $route table 200 2>/dev/null || true
done
ip rule add from $LOCAL_IP pref 100 table 200 2>/dev/null || true
EOF
chmod +x /usr/local/bin/vps-inbound-protect.sh

echo "[*] 6/7 自动生成系统守护进程配置 ($INIT_SYS)..."
echo -e "vpn\nvpn" > /etc/vpngate/auth.txt
chmod 600 /etc/vpngate/auth.txt
if [ ! -f /etc/vpngate/settings.json ]; then
    echo '{"interval": 60, "daemon_enabled": false, "target_ip": "", "country": "JP", "tg_token": "", "tg_chat_id": "", "filter_softether": true}' > /etc/vpngate/settings.json
fi

if [ "$INIT_SYS" = "systemd" ]; then
    cat << 'EOF' > /etc/systemd/system/vps-inbound-protect.service
[Unit]
Description=Protect VPS Inbound Routing for VPN Gate
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vps-inbound-protect.sh
[Install]
WantedBy=multi-user.target
EOF
    cat << 'EOF' > /etc/systemd/system/vpngate.service
[Unit]
Description=VPN Gate Global Egress
After=network.target vps-inbound-protect.service
[Service]
ExecStart=/usr/sbin/openvpn --config /etc/vpngate/current.ovpn
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    cat << 'EOF' > /etc/systemd/system/vpngate-daemon.service
[Unit]
Description=VPN Gate TG Bot & Auto-Heal Daemon
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/vpngate daemon
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
elif [ "$INIT_SYS" = "openrc" ]; then
    cat << 'EOF' > /etc/init.d/vps-inbound-protect
#!/sbin/openrc-run
description="Protect VPS Inbound Routing for VPN Gate"
depend() { after network; }
start() { ebegin "Starting routing protection"; /usr/local/bin/vps-inbound-protect.sh; eend $?; }
EOF
    cat << 'EOF' > /etc/init.d/vpngate
#!/sbin/openrc-run
description="VPN Gate Global Egress"
command="/usr/sbin/openvpn"
command_args="--config /etc/vpngate/current.ovpn"
command_background="yes"
pidfile="/run/vpngate.pid"
depend() { after net vps-inbound-protect; }
EOF
    cat << 'EOF' > /etc/init.d/vpngate-daemon
#!/sbin/openrc-run
description="VPN Gate TG Bot & Auto-Heal Daemon"
command="/usr/local/bin/vpngate"
command_args="daemon"
command_background="yes"
pidfile="/run/vpngate-daemon.pid"
depend() { after net; }
EOF
    chmod +x /etc/init.d/vps-inbound-protect /etc/init.d/vpngate /etc/init.d/vpngate-daemon
fi

echo "[*] 7/7 编译写入 Python 全栈管理内核..."
cat << 'EOF' > /usr/local/bin/vpngate
#!/usr/bin/env python3
import urllib.request
import urllib.parse
import json
import csv
import base64
import sys
import subprocess
import time
import os
import socket
import concurrent.futures

API_URL = "https://www.vpngate.net/api/iphone/"
OVPN_FILE = "/etc/vpngate/current.ovpn"
SETTINGS_FILE = "/etc/vpngate/settings.json"
MAIN_IP_FILE = "/etc/vpngate/main_ip.txt"
TG_CACHE_FILE = "/etc/vpngate/tg_cache.json"

def get_main_ip():
    try:
        with open(MAIN_IP_FILE, "r") as f: return f.read().strip()
    except: return ""

def load_settings():
    try:
        with open(SETTINGS_FILE, "r") as f: 
            s = json.load(f)
            if "filter_softether" not in s: s["filter_softether"] = True
            if "interval" not in s: s["interval"] = 60
            return s
    except: return {"interval": 60, "daemon_enabled": False, "target_ip": "", "country": "JP", "tg_token": "", "tg_chat_id": "", "filter_softether": True}

def save_settings(settings):
    with open(SETTINGS_FILE, "w") as f: json.dump(settings, f)

def svc_cmd(action, srv):
    if os.path.exists("/sbin/rc-service"):
        subprocess.run(["rc-service", srv, action], check=False)
    else:
        subprocess.run(["systemctl", action, srv], check=False)

def tcp_ping(ip, port, timeout=1.5):
    try:
        st = time.time()
        s = socket.create_connection((ip, port), timeout=timeout)
        s.close()
        return (time.time() - st) * 1000
    except: return 9999.0

def probe_node(node):
    conf = base64.b64decode(node['b64']).decode('utf-8', errors='ignore')
    port = 1194
    proto = 'udp'
    for line in conf.splitlines():
        if line.startswith('remote '):
            parts = line.split()
            if len(parts) >= 3:
                try: port = int(parts[2])
                except: pass
        elif line.startswith('proto '):
            if len(line.split()) > 1:
                proto = line.split()[1].strip()
    
    ports_to_try = []
    if proto == 'tcp': ports_to_try.append(port)
    for p in [443, 1194, 995]:
        if p not in ports_to_try: ports_to_try.append(p)
            
    latency = 9999.0
    for p in ports_to_try:
        lat = tcp_ping(node['ip'], p)
        if lat < 9999.0:
            latency = lat
            break
            
    if latency == 9999.0:
        try:
            st = time.time()
            res = subprocess.run(["ping", "-c", "1", "-W", "1", node['ip']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode == 0: latency = (time.time() - st) * 1000
        except: pass
    return latency

def batch_real_geo_info(ips):
    results = {}
    chunk_size = 90
    for i in range(0, len(ips), chunk_size):
        chunk = ips[i:i+chunk_size]
        try:
            data = json.dumps([{"query": ip} for ip in chunk]).encode('utf-8')
            req = urllib.request.Request("http://ip-api.com/batch?fields=query,isp,city,regionName", data=data)
            with urllib.request.urlopen(req, timeout=8) as res:
                res_data = json.loads(res.read().decode('utf-8'))
                for item in res_data:
                    results[item['query']] = {
                        'isp': item.get('isp', 'Unknown'),
                        'region': item.get('regionName', ''),
                        'city': item.get('city', '')
                    }
        except: pass
    return results

def fetch_nodes(target_country, get_asn=False):
    settings = load_settings()
    filter_softether = settings.get("filter_softether", True)
    bad_keywords = ["softether", "daiyuu", "academic", "tsukuba", "vpngate", "dncservers"]
    
    req = urllib.request.Request(API_URL, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            html = response.read().decode('utf-8')
    except: return []
        
    lines = [line for line in html.splitlines() if line and not line.startswith("*")]
    reader = csv.DictReader(lines)
    nodes = []
    target_cc = target_country.strip().upper()
    
    for row in reader:
        country_short = row.get("CountryShort", "").strip().upper()
        if country_short == target_cc and row.get("OpenVPN_ConfigData_Base64"):
            operator = row.get("Operator", "Unknown")
            if filter_softether:
                op_lower = operator.lower()
                if any(k in op_lower for k in bad_keywords):
                    continue
            nodes.append({
                'ip': row.get("IP"), 'country': country_short,
                'speed': int(row.get("Speed", 0)) / 1000000,
                'operator': operator, 'region': 'Unknown',
                'b64': row.get("OpenVPN_ConfigData_Base64")
            })
            
    nodes.sort(key=lambda x: -x['speed'])
    worker_count = min(len(nodes) or 1, 100)
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
        future_to_node = {executor.submit(probe_node, n): n for n in nodes}
        for future in concurrent.futures.as_completed(future_to_node):
            n = future_to_node[future]
            n['ping'] = future.result()
            
    if get_asn:
        ips = [n['ip'] for n in nodes if n['ping'] < 2000.0]
        geo_data = batch_real_geo_info(ips)
        for n in nodes:
            info = geo_data.get(n['ip'], {})
            n['operator'] = info.get('isp', n['operator'])[:25]
            loc = f"{info.get('region', '')} {info.get('city', '')}".strip()
            n['region'] = loc[:12] if loc else "Unknown"
            
    valid_nodes = [n for n in nodes if n['ping'] < 2000.0]
    valid_nodes.sort(key=lambda x: (x['ping'], -x['speed']))
    return valid_nodes

def write_config(node):
    raw_config = base64.b64decode(node['b64']).decode("utf-8", errors="ignore")
    custom_options = [
        "\n# --- 全局代理注入 ---",
        "dev vpngate0", "dev-type tun", "auth-user-pass /etc/vpngate/auth.txt",
        "redirect-gateway def1 bypass-dhcp", "auth-nocache", "resolv-retry infinite", "nobind"
    ]
    with open(OVPN_FILE, "w") as f:
        f.write(raw_config + "\n" + "\n".join(custom_options))

def get_current_full_info():
    try:
        res = subprocess.run(["curl", "-s", "--max-time", "5", "http://ip-api.com/json"], stdout=subprocess.PIPE, text=True)
        if res.returncode == 0: return json.loads(res.stdout)
    except: pass
    return {}

def send_tg_message(text, reply_markup=None):
    settings = load_settings()
    token = settings.get("tg_token", "").strip()
    chat_id = settings.get("tg_chat_id", "").strip()
    if not token or not chat_id: return
    
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}
    if reply_markup: payload["reply_markup"] = reply_markup
    req = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'), headers={'Content-Type': 'application/json'})
    try: urllib.request.urlopen(req, timeout=5)
    except: pass

def send_tg_menu():
    settings = load_settings()
    cc = settings.get("country", "JP")
    status = "🟢已开启" if settings.get("daemon_enabled") else "🔴已停用"
    text = f"🖥 *VPN Gate 主菜单* \n\n🌍 当前目标: `{cc}`\n🛡 守护状态: {status}"
    keyboard = {
        "inline_keyboard": [
            [{"text": "🚀 1. 自动智能拨号", "callback_data": "tg_dial"}, {"text": "🔍 2. 手动测速选点", "callback_data": "tg_manual"}],
            [{"text": "🛑 3. 停止 (恢复直连)", "callback_data": "tg_stop"}, {"text": "📊 4. 查看出站状态", "callback_data": "tg_status"}],
            [{"text": "⚙️ 5. 系统设置面板", "callback_data": "tg_settings"}]
        ]
    }
    send_tg_message(text, keyboard)

def send_tg_settings():
    settings = load_settings()
    cc = settings.get("country", "JP")
    daemon = "🟢ON" if settings.get("daemon_enabled") else "🔴OFF"
    flt = "🟢ON" if settings.get("filter_softether") else "🔴OFF"
    interval = settings.get("interval", 60)
    
    text = f"⚙️ *系统设置面板*\n当前可进行各项核心配置调整："
    keyboard = {
        "inline_keyboard": [
            [{"text": f"🌍 切换国家 (当前:{cc})", "callback_data": "tg_cc"}],
            [{"text": f"🛡 守护开关 ({daemon})", "callback_data": "tg_daemon"}, {"text": f"🧹 过滤官方节点 ({flt})", "callback_data": "tg_filter"}],
            [{"text": f"⏱ 修改周期 ({interval}s)", "callback_data": "tg_interval"}],
            [{"text": "🔙 返回主菜单", "callback_data": "tg_back"}]
        ]
    }
    send_tg_message(text, keyboard)

def handle_telegram_updates():
    settings = load_settings()
    token = settings.get("tg_token", "").strip()
    chat_id = settings.get("tg_chat_id", "").strip()
    if not token or not chat_id: return
        
    offset_file = "/etc/vpngate/tg_offset.txt"
    offset = 0
    if os.path.exists(offset_file):
        try:
            with open(offset_file, "r") as f: offset = int(f.read().strip())
        except: pass
            
    url = f"https://api.telegram.org/bot{token}/getUpdates?offset={offset}&timeout=2"
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as res:
            data = json.loads(res.read().decode('utf-8'))
            if data.get("ok"):
                for update in data.get("result", []):
                    offset = update["update_id"] + 1
                    with open(offset_file, "w") as f: f.write(str(offset))
                    
                    req_chat_id, text, callback_data = "", "", ""
                    if "message" in update:
                        req_chat_id = str(update["message"].get("chat", {}).get("id"))
                        text = update["message"].get("text", "").strip()
                    elif "callback_query" in update:
                        req_chat_id = str(update["callback_query"].get("message", {}).get("chat", {}).get("id"))
                        callback_data = update["callback_query"].get("data", "")
                        
                    if req_chat_id != str(chat_id): continue
                    
                    if text in ["/start", "/menu"]: 
                        send_tg_menu()
                    elif text.startswith("/cc "):
                        new_cc = text.split(" ")[1].strip().upper()
                        if len(new_cc) == 2:
                            settings['country'] = new_cc; save_settings(settings)
                            send_tg_message(f"[√] 国家已切换为: `{new_cc}`")
                            send_tg_settings()
                    elif text.startswith("/interval "):
                        try:
                            val = int(text.split(" ")[1].strip())
                            if val >= 10:
                                settings['interval'] = val; save_settings(settings)
                                send_tg_message(f"[√] 巡检周期已修改为: `{val} 秒`")
                                send_tg_settings()
                        except: pass
                    elif text.startswith("/dial "):
                        try:
                            idx = int(text.split(" ")[1].strip()) - 1
                            with open(TG_CACHE_FILE, "r") as f: cached_nodes = json.load(f)
                            if 0 <= idx < len(cached_nodes):
                                send_tg_message(f"[*] 正在后台连接节点 `{idx+1}` ...")
                                svc_cmd("stop", "vpngate")
                                time.sleep(1)
                                success = False
                                for node in cached_nodes[idx:]:
                                    if dial_and_verify(node):
                                        success = True; break
                                if not success: send_tg_message("[!] 所选节点及后续节点均拨号失败。")
                            else: send_tg_message("[!] 编号无效。")
                        except: send_tg_message("[!] 请先点击「手动测速选点」。")
                        
                    if callback_data == "tg_dial":
                        send_tg_message(f"[*] 正在后台并发测速智能拨号...")
                        svc_cmd("stop", "vpngate")
                        time.sleep(1)
                        auto_dial(settings.get("country", "JP"))
                    elif callback_data == "tg_manual":
                        cc = settings.get("country", "JP")
                        send_tg_message(f"[-] 正在全量并发 TCPing 测速并解析 `{cc}` 地理位置，请稍候...")
                        nodes = fetch_nodes(cc, get_asn=True)
                        if not nodes:
                            send_tg_message(f"[!] 未能测通任何 `{cc}` 节点。")
                        else:
                            with open(TG_CACHE_FILE, "w") as f: json.dump(nodes[:25], f)
                            lines = [f"🌍 *{cc} 节点列表 (Ping优先)*", "```text"]
                            for i, n in enumerate(nodes[:25]):
                                loc = n['region'][:6]
                                op = n['operator'][:10]
                                lines.append(f"[{i+1:<2}] {n['ping']:<3.0f}ms | {n['speed']:>4.0f}M | {loc} | {op}")
                            lines.append("```")
                            msg = "\n".join(lines) + "\n\n👉 **请直接回复指令拨号，例如：** `/dial 1`"
                            send_tg_message(msg)
                    elif callback_data == "tg_stop":
                        svc_cmd("stop", "vpngate")
                        settings['target_ip'] = ""; save_settings(settings)
                        send_tg_message("[√] 已停止代理，恢复本机出口。")
                    elif callback_data == "tg_status":
                        info = get_current_full_info()
                        curr = info.get("query", "Unknown")
                        st = "直连本机" if curr == get_main_ip() else "VPN 代理中"
                        send_tg_message(f"*状态*\n• 状态: `{st}`\n• IP: `{curr}`\n• 地区: `{info.get('regionName', '')} {info.get('city', '')}`\n• ASN: `{info.get('isp')}`")
                    elif callback_data == "tg_settings":
                        send_tg_settings()
                    elif callback_data == "tg_back":
                        send_tg_menu()
                    elif callback_data == "tg_cc":
                        send_tg_message("请直接发送指令切换国家，例如：\n`/cc HK`\n`/cc US`")
                    elif callback_data == "tg_interval":
                        send_tg_message("请直接发送指令修改巡检周期，例如：\n`/interval 60`\n`/interval 120`")
                    elif callback_data == "tg_daemon":
                        settings['daemon_enabled'] = not settings['daemon_enabled']; save_settings(settings)
                        send_tg_settings()
                    elif callback_data == "tg_filter":
                        settings['filter_softether'] = not settings.get('filter_softether', True); save_settings(settings)
                        send_tg_settings()
    except: pass

def dial_and_verify(node):
    print(f"[-] 正在拨号: {node['ip']} (TCPing: {node['ping']:.1f}ms)...")
    write_config(node)
    
    subprocess.run(["/usr/local/bin/vps-inbound-protect.sh"], check=False)
    svc_cmd("restart", "vpngate")
    
    for i in range(6):
        time.sleep(3)
        info = get_current_full_info()
        curr = info.get("query", "")
        if curr and curr != get_main_ip():
            msg = f"[√] 拨号成功！\n出站IP: `{curr}`\n地区: `{info.get('regionName', '')} {info.get('city', '')}`\n真实ASN: `{info.get('isp', 'Unknown')}`"
            print(msg)
            s = load_settings(); s['target_ip'] = curr; save_settings(s)
            send_tg_message(msg)
            return True
            
    print(f"[!] {node['ip']} 连接超时或出站IP仍为本机，立即切断！")
    svc_cmd("stop", "vpngate")
    time.sleep(1)
    return False

def auto_dial(target_country):
    print(f"[-] 正在获取所有 [{target_country}] 节点，进行全量并发测速...")
    nodes = fetch_nodes(target_country, get_asn=False)
    if not nodes:
        print("[!] 未找到可用节点。"); return False
    for node in nodes[:20]:
        if dial_and_verify(node): return True
    return False

def daemon_process():
    while True:
        settings = load_settings()
        handle_telegram_updates()
        if settings.get("daemon_enabled"):
            curr_ip = get_current_full_info().get("query", "")
            main_ip = get_main_ip()
            target_ip = settings.get("target_ip")
            target_country = settings.get("country", "JP")
            
            if not curr_ip or curr_ip == main_ip or (target_ip and curr_ip != target_ip):
                print(f"[{time.strftime('%H:%M:%S')}] IP 异常，切断死链并启动 [{target_country}] 自动重连...")
                svc_cmd("stop", "vpngate")
                time.sleep(2)
                auto_dial(target_country)
                
        time.sleep(max(3, settings.get("interval", 60)/10))

def settings_menu():
    while True:
        settings = load_settings()
        print(f"\n============= 系统与守护设置 =============")
        print(f" 1. 切换目标国家 [当前: {settings.get('country', 'JP')}]")
        print(f" 2. 开/关 后台守护 [当前: {'🟢已开启' if settings['daemon_enabled'] else '🔴已停用'}]")
        print(f" 3. 开/关 过滤官方节点 [当前: {'🟢已开启' if settings.get('filter_softether') else '🔴已停用'}]")
        print(f" 4. 修改守护巡检周期 [当前: {settings.get('interval', 60)} 秒]")
        print(f" 5. 绑定 Telegram 控制")
        print(" 0. 返回主菜单")
        print("==========================================")
        c = input("请选择 [0-5]: ").strip()
        if c == '1':
            cc = input("请输入两位国码 (如 HK, JP, US): ").strip().upper()
            if len(cc) == 2: settings['country'] = cc; save_settings(settings)
        elif c == '2':
            settings['daemon_enabled'] = not settings['daemon_enabled']; save_settings(settings)
        elif c == '3':
            settings['filter_softether'] = not settings.get('filter_softether', True); save_settings(settings)
            print(f"[√] 官方/学术节点过滤已{'开启' if settings['filter_softether'] else '关闭'}")
        elif c == '4':
            try:
                new_int = int(input("请输入周期(秒, 最低10秒): "))
                if new_int >= 10:
                    settings['interval'] = new_int; save_settings(settings)
            except: pass
        elif c == '5':
            token = input("请输入 Telegram Bot Token: ").strip()
            chat_id = input("请输入你的 Telegram Chat ID: ").strip()
            if token: settings['tg_token'] = token
            if chat_id: settings['tg_chat_id'] = chat_id
            save_settings(settings)
            print("[√] TG 绑定成功！")
        elif c == '0': break

def main_menu():
    while True:
        s = load_settings()
        curr_cc = s.get('country', 'JP')
        print(f"\n======== VPN Gate 满血控制面板 [{curr_cc}] ========")
        print(" 1. 自动智能拨号 (全量节点并发 TCPing 测速排序)")
        print(" 2. 手动选择节点 (无限制展示、含具体地区与真ASN)")
        print(" 3. 停止连接 (恢复 VPS 本机出口)")
        print(" 4. 查看当前网络详细状态")
        print(" 5. 系统与设置 (国家 / 巡检 / 过滤 / Telegram)")
        print(" 0. 退出面板")
        print("===================================================")
        c = input("请选择操作 [0-5]: ").strip()
        
        if c == '1': 
            svc_cmd("stop", "vpngate")
            time.sleep(1)
            auto_dial(curr_cc)
        elif c == '2':
            svc_cmd("stop", "vpngate")
            print(f"[-] 正在全量并发 TCPing 测速并解析 [{curr_cc}] 的地理位置，请稍候...")
            nodes = fetch_nodes(curr_cc, get_asn=True)
            if not nodes:
                print(f"[!] 未能测通任何 [{curr_cc}] 节点。")
                continue
            print(f"\n================ [{curr_cc}] 节点列表 (共 {len(nodes)} 个可用) ================")
            print(f" {'ID':<3} | {'IP 地址':<15} | {'Ping':<5} | {'带宽':<5} | {'地区 (Region)':<13} | {'真实 ASN / ISP'}")
            print("------------------------------------------------------------------------------------------------")
            for i, n in enumerate(nodes):
                print(f" [{i+1:<2}] | {n['ip']:<15} | {n['ping']:<4.0f} | {n['speed']:>4.0f}M | {n['region']:<14} | {n['operator']}")
            print("================================================================================================")
            sel = input(f"\n请选择起始节点 ID [1-{len(nodes)} | 0 返回]: ").strip()
            if sel.isdigit() and 1 <= int(sel) <= len(nodes):
                for node in nodes[int(sel)-1:]:
                    if dial_and_verify(node): break
        elif c == '3':
            svc_cmd("stop", "vpngate")
            s['target_ip'] = ""; save_settings(s)
            print("[√] 已断开代理，恢复直连。")
        elif c == '4':
            info = get_current_full_info()
            curr = info.get("query", "Unknown")
            if curr == get_main_ip(): print(f"[*] 当前直连本机 | IP: {curr}")
            else: print(f"[√] VPN 代理中 | IP: {curr} | 地区: {info.get('regionName', '')} {info.get('city', '')} | 真实 ASN: {info.get('isp')}")
        elif c == '5': settings_menu()
        elif c == '0': break

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "daemon": daemon_process()
    else: main_menu()
EOF
chmod +x /usr/local/bin/vpngate

if [ "$INIT_SYS" = "systemd" ]; then
    systemctl daemon-reload
    systemctl enable --now vps-inbound-protect.service
    systemctl restart vpngate-daemon.service
elif [ "$INIT_SYS" = "openrc" ]; then
    rc-update add vps-inbound-protect default >/dev/null 2>&1 || true
    rc-update add vpngate-daemon default >/dev/null 2>&1 || true
    rc-service vps-inbound-protect start >/dev/null 2>&1 || true
    rc-service vpngate-daemon restart >/dev/null 2>&1 || true
fi

echo "[√] 部署完毕！适配引擎已启动。请运行 vpngate 体验无缝穿越！"
