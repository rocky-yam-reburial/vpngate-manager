cat << 'EOF' > install_vpngate.sh
#!/usr/bin/env bash
set -e

echo "======================================================="
echo "        VPN Gate 最终版 1.0 (双模控制 + 全栈看门狗)        "
echo "======================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[!] 请使用 root 权限运行此脚本"
    exit 1
fi

echo "[*] 1/8 硬件与虚拟化环境校验 (TUN/TAP)..."
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net 2>/dev/null || true
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
    if [ ! -c /dev/net/tun ]; then
        echo "[!] 致命错误: TUN/TAP 未开启，请在服务商后台开启并重启机器。"
        exit 1
    fi
fi

echo "[*] 2/8 安装系统依赖包 (自适应 Alpine/Debian/RedHat)..."
if [ -f /etc/alpine-release ]; then
    apk update > /dev/null
    apk add bash curl python3 openvpn iproute2 procps iptables e2fsprogs cronie > /dev/null
elif [ -f /etc/debian_version ]; then
    apt-get update -y > /dev/null
    apt-get install -y curl python3 openvpn iproute2 procps iptables e2fsprogs cron > /dev/null
elif [ -f /etc/redhat-release ]; then
    yum install -y curl python3 openvpn iproute procps-ng iptables e2fsprogs cronie > /dev/null
fi

echo "[*] 3/8 探测系统守护进程..."
if command -v systemctl >/dev/null 2>&1; then 
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then 
    INIT_SYS="openrc"
else 
    echo "[!] 未知守护进程系统，安装中止。"
    exit 1
fi

echo "[*] 4/8 关死 IPv6 并固化公共 DNS..."
MAIN_DEV=$(ip -4 route show table main 2>/dev/null | grep -E '^default' | grep -E -v 'tun|vpn|ppp|wg' | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
[ -z "$MAIN_DEV" ] && MAIN_DEV=$(ip -4 -o link show | awk -F': ' '{print $2}' | grep -E -v 'lo|tun|vpn|ppp|wg' | head -n1)
LOCAL_IP=$(ip -4 -o addr show dev "$MAIN_DEV" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

PUBLIC_IP=$(curl -s --max-time 5 http://ip-api.com/json | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP=$LOCAL_IP; fi

mkdir -p /etc/vpngate
echo "$PUBLIC_IP" > /etc/vpngate/main_ip.txt

sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true
if [ -n "$MAIN_DEV" ]; then
    sysctl -w net.ipv6.conf.$MAIN_DEV.disable_ipv6=1 >/dev/null 2>&1 || true
    ip -6 addr flush dev $MAIN_DEV 2>/dev/null || true
fi

cat << SYS_EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYS_EOF
if [ -n "$MAIN_DEV" ]; then
    echo "net.ipv6.conf.$MAIN_DEV.disable_ipv6 = 1" >> /etc/sysctl.d/99-disable-ipv6.conf
fi
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat << 'DNS_EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS_EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "[*] 5/8 注入防断网策略路由核心..."
cat << 'ROUTE_EOF' > /usr/local/bin/vps-inbound-protect.sh
#!/usr/bin/env bash
MAIN_DEV=$(ip -4 route show table main 2>/dev/null | grep -E '^default' | grep -E -v 'tun|vpn|ppp|wg' | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
[ -z "$MAIN_DEV" ] && MAIN_DEV=$(ip -4 -o link show | awk -F': ' '{print $2}' | grep -E -v 'lo|tun|vpn|ppp|wg' | head -n1)
LOCAL_IP=$(ip -4 -o addr show dev "$MAIN_DEV" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)

sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
if [ -n "$MAIN_DEV" ]; then sysctl -w net.ipv4.conf.$MAIN_DEV.rp_filter=0 >/dev/null 2>&1 || true; fi

ip rule del from $LOCAL_IP table 200 2>/dev/null || true
ip rule del fwmark 0x200 table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true
iptables -t mangle -D PREROUTING -i $MAIN_DEV -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x200 2>/dev/null || true
iptables -t mangle -D OUTPUT -m connmark --mark 0x200 -j MARK --set-mark 0x200 2>/dev/null || true

ip -4 route show table main | grep -E -v 'tun|vpn|ppp|wg' | while read -r route; do
    ip route add $route table 200 2>/dev/null || true
done

ip rule add from $LOCAL_IP pref 100 table 200 2>/dev/null || true
iptables -t mangle -A PREROUTING -i $MAIN_DEV -m conntrack --ctstate NEW -j CONNMARK --set-mark 0x200 2>/dev/null || true
iptables -t mangle -A OUTPUT -m connmark --mark 0x200 -j MARK --set-mark 0x200 2>/dev/null || true
ip rule add fwmark 0x200 pref 99 table 200 2>/dev/null || true
ROUTE_EOF
chmod +x /usr/local/bin/vps-inbound-protect.sh

echo "[*] 6/8 配置专业风控与防滥用 API 凭据..."
SETTINGS_FILE="/etc/vpngate/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"interval": 20, "daemon_enabled": true, "target_ip": "", "country": "JP", "filter_softether": true}' > "$SETTINGS_FILE"
fi

OLD_ABUSE=$(python3 -c "import json; print(json.load(open('$SETTINGS_FILE')).get('abuseipdb_key', ''))" 2>/dev/null || echo "")
OLD_IPQS=$(python3 -c "import json; print(json.load(open('$SETTINGS_FILE')).get('ipqs_key', ''))" 2>/dev/null || echo "")
OLD_IPINFO=$(python3 -c "import json; print(json.load(open('$SETTINGS_FILE')).get('ipinfo_token', ''))" 2>/dev/null || echo "")

echo "----------------------------------------------------------"
echo "提示：直接回车可保持原配置不变或留空跳过。"
read -p "👉 AbuseIPDB API Key [当前: ${OLD_ABUSE:-未配置}]: " IN_ABUSE
read -p "👉 IPQualityScore (IPQS) API Key [当前: ${OLD_IPQS:-未配置}]: " IN_IPQS
read -p "👉 IPinfo.io Token [当前: ${OLD_IPINFO:-未配置}]: " IN_IPINFO
echo "----------------------------------------------------------"

python3 - << PY_SET
import json
path = "$SETTINGS_FILE"
try:
    with open(path, "r") as f: d = json.load(f)
except: d = {}

ia = """$IN_ABUSE""".strip()
iq = """$IN_IPQS""".strip()
ii = """$IN_IPINFO""".strip()

if ia: d["abuseipdb_key"] = ia
if iq: d["ipqs_key"] = iq
if ii: d["ipinfo_token"] = ii
if "interval" not in d: d["interval"] = 20
if "country" not in d: d["country"] = "JP"
if "filter_softether" not in d: d["filter_softether"] = True
d["daemon_enabled"] = True

with open(path, "w") as f: json.dump(d, f, indent=2)
PY_SET

echo "[*] 7/8 部署系统级看门狗与 Cron 哨兵..."
echo -e "vpn\nvpn" > /etc/vpngate/auth.txt; chmod 600 /etc/vpngate/auth.txt

if [ "$INIT_SYS" = "systemd" ]; then
    cat << 'SRV_EOF' > /etc/systemd/system/vps-inbound-protect.service
[Unit]
Description=Protect VPS Inbound Routing
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vps-inbound-protect.sh
[Install]
WantedBy=multi-user.target
SRV_EOF
    cat << 'SRV_EOF' > /etc/systemd/system/vpngate.service
[Unit]
Description=VPN Gate Global Egress
After=network.target vps-inbound-protect.service
[Service]
ExecStart=/usr/sbin/openvpn --config /etc/vpngate/current.ovpn
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SRV_EOF
    cat << 'SRV_EOF' > /etc/systemd/system/vpngate-daemon.service
[Unit]
Description=VPN Gate Auto-Heal & Watchdog Daemon
After=network-online.target vps-inbound-protect.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/vpngate daemon
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
SRV_EOF
elif [ "$INIT_SYS" = "openrc" ]; then
    cat << 'SRV_EOF' > /etc/init.d/vps-inbound-protect
#!/sbin/openrc-run
depend() { after network; }
start() { ebegin "Starting routing protection"; /usr/local/bin/vps-inbound-protect.sh; eend $?; }
SRV_EOF
    cat << 'SRV_EOF' > /etc/init.d/vpngate
#!/sbin/openrc-run
command="/usr/sbin/openvpn"
command_args="--config /etc/vpngate/current.ovpn"
command_background="yes"
pidfile="/run/vpngate.pid"
depend() { after net vps-inbound-protect; }
SRV_EOF
    cat << 'SRV_EOF' > /etc/init.d/vpngate-daemon
#!/sbin/openrc-run
command="/usr/local/bin/vpngate"
command_args="daemon"
command_background="yes"
pidfile="/run/vpngate-daemon.pid"
depend() { after net; }
SRV_EOF
    chmod +x /etc/init.d/vps-inbound-protect /etc/init.d/vpngate /etc/init.d/vpngate-daemon
fi

cat << 'WD_EOF' > /usr/local/bin/vpngate-watchdog.sh
#!/usr/bin/env bash
SETTINGS="/etc/vpngate/settings.json"
[ ! -f "$SETTINGS" ] && exit 0

ENABLED=$(python3 -c "import json; print(json.load(open('$SETTINGS')).get('daemon_enabled', True))" 2>/dev/null || echo "False")
[ "$ENABLED" != "True" ] && exit 0

RESTART_CMD="systemctl restart vpngate-daemon"
command -v rc-service >/dev/null 2>&1 && RESTART_CMD="rc-service vpngate-daemon restart"

if ! pgrep -f "vpngate daemon" >/dev/null 2>&1; then
    $RESTART_CMD
    exit 0
fi

if ! pgrep -x "openvpn" >/dev/null 2>&1; then
    $RESTART_CMD
    exit 0
fi
WD_EOF
chmod +x /usr/local/bin/vpngate-watchdog.sh

CRON_FILE="/etc/cron.d/vpngate_watchdog"
mkdir -p /etc/cron.d
echo "* * * * * root /usr/local/bin/vpngate-watchdog.sh >/dev/null 2>&1" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo "[*] 8/8 编译控制核心 (VPN Gate 最终版 1.0)..."
cat << 'PY_EOF' > /usr/local/bin/vpngate
#!/usr/bin/env python3
import urllib.request, json, csv, base64, sys, subprocess, time, os, socket, concurrent.futures

API_URL = "https://www.vpngate.net/api/iphone/"
OVPN_FILE = "/etc/vpngate/current.ovpn"
SETTINGS_FILE = "/etc/vpngate/settings.json"
MAIN_IP_FILE = "/etc/vpngate/main_ip.txt"

C_RESET = "\033[0m"
C_S = "\033[1;32m"  # S 绿色
C_A = "\033[1;34m"  # A 蓝色
C_B = "\033[1;33m"  # B 黄色
C_C = "\033[1;31m"  # C 红色

def get_main_ip():
    try:
        with open(MAIN_IP_FILE, "r") as f: return f.read().strip()
    except: return ""

def load_settings():
    try:
        with open(SETTINGS_FILE, "r") as f: 
            s = json.load(f)
            if "filter_softether" not in s: s["filter_softether"] = True
            if "interval" not in s: s["interval"] = 20
            if "daemon_enabled" not in s: s["daemon_enabled"] = True
            return s
    except: return {"interval": 20, "daemon_enabled": True, "target_ip": "", "country": "JP", "filter_softether": True}

def save_settings(settings):
    with open(SETTINGS_FILE, "w") as f: json.dump(settings, f, indent=2)

def svc_cmd(action, srv):
    if os.path.exists("/sbin/rc-service"): subprocess.run(["rc-service", srv, action], check=False)
    else: subprocess.run(["systemctl", action, srv], check=False)

def is_process_running(proc_name):
    try:
        out = subprocess.check_output(["pgrep", "-f", proc_name]).decode()
        return len(out.strip()) > 0
    except:
        return False

def force_clean_routes():
    svc_cmd("stop", "vpngate")
    subprocess.run(["killall", "-9", "openvpn"], stderr=subprocess.DEVNULL)
    subprocess.run(["ip", "link", "delete", "vpngate0"], stderr=subprocess.DEVNULL)
    subprocess.run(["/usr/local/bin/vps-inbound-protect.sh"], check=False)
    time.sleep(1)

def get_current_full_info():
    s = load_settings()
    token = s.get("ipinfo_token", "")
    try:
        url = "https://ipinfo.io/json" + (f"?token={token}" if token else "")
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=4) as res:
            d = json.loads(res.read().decode())
            if d.get("ip"):
                loc = f"{d.get('country', '')} {d.get('region', '')} {d.get('city', '')}".strip()
                return {"query": d.get("ip"), "location": loc or "Unknown", "isp": d.get("org", "Unknown")}
    except: pass

    try:
        res = subprocess.run(["curl", "-s", "--max-time", "3", "http://ip-api.com/json"], stdout=subprocess.PIPE, text=True)
        if res.returncode == 0:
            d = json.loads(res.stdout)
            if d.get("query"):
                loc = f"{d.get('countryCode', '')} {d.get('regionName', '')} {d.get('city', '')}".strip()
                return {"query": d.get("query"), "location": loc or "Unknown", "isp": d.get("as", "") or d.get("isp", "Unknown")}
    except: pass

    for api in ["https://api.ipify.org", "https://api.ip.sb/ip", "http://checkip.amazonaws.com"]:
        try:
            res = subprocess.run(["curl", "-s", "--max-time", "3", api], stdout=subprocess.PIPE, text=True)
            ip_str = res.stdout.strip()
            if res.returncode == 0 and ip_str and "." in ip_str:
                return {"query": ip_str, "location": "Unknown", "isp": "Unknown"}
        except: pass
    return {}

# --- 核心安全与风控检测模块 ---

def check_dnsbl(ip):
    rev_ip = ".".join(reversed(ip.strip().split(".")))
    rbl_list = {
        "Spamhaus ZEN (黑客/肉鸡/PBL)": "zen.spamhaus.org",
        "Barracuda (恶意攻击/漏洞扫描)": "b.barracudacentral.org",
        "DroneBL (公开代理/IRC滥用)": "dnsbl.dronebl.org",
        "SpamCop (垃圾发包/网络滥用)": "bl.spamcop.net",
        "SORBS Combined (综合安全黑名单)": "dnsbl.sorbs.net"
    }
    results = {}
    for name, host in rbl_list.items():
        query = f"{rev_ip}.{host}"
        try:
            socket.setdefaulttimeout(1.5)
            socket.gethostbyname(query)
            results[name] = True
        except:
            results[name] = False
    return results

def check_abuseipdb(ip, key):
    if not key: return None
    url = f"https://api.abuseipdb.com/api/v2/check?ipAddress={ip}&maxAgeInDays=90"
    req = urllib.request.Request(url, headers={"Key": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=4) as res:
            d = json.loads(res.read().decode()).get("data", {})
            return {
                "score": d.get("abuseConfidenceScore", 0),
                "reports": d.get("totalReports", 0),
                "last_reported": d.get("lastReportedAt", "无记录")
            }
    except Exception as e:
        return {"error": str(e)}

def get_native_ip_type(ip, settings):
    conn_type = "Unknown"
    is_residential = False
    is_hosting = True
    org_name = ""
    location = ""

    ipqs_key = settings.get("ipqs_key", "")
    ipqs_data = {}
    if ipqs_key:
        try:
            url = f"https://ipqualityscore.com/api/json/ip/{ipqs_key}/{ip}?strictness=1"
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=4) as res:
                ipqs_data = json.loads(res.read().decode())
                ct = ipqs_data.get("connection_type", "")
                if ct:
                    conn_type = ct
                    if "residential" in ct.lower():
                        is_residential = True
                        is_hosting = False
                    elif "data center" in ct.lower():
                        is_residential = False
                        is_hosting = True
                if not location:
                    location = f"{ipqs_data.get('country_code', '')} {ipqs_data.get('region', '')} {ipqs_data.get('city', '')}".strip()
                if not org_name:
                    org_name = ipqs_data.get("ISP", "") or ipqs_data.get("organization", "")
        except: pass

    token = settings.get("ipinfo_token", "")
    try:
        url = f"https://ipinfo.io/{ip}/json"
        if token: url += f"?token={token}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=4) as res:
            info_d = json.loads(res.read().decode())
            if info_d.get("org"): org_name = info_d.get("org")
            if not location:
                location = f"{info_d.get('country', '')} {info_d.get('region', '')} {info_d.get('city', '')}".strip()
            
            asn_type = info_d.get("asn", {}).get("type", "")
            comp_type = info_d.get("company", {}).get("type", "")
            
            if conn_type == "Unknown":
                if asn_type == "isp" or comp_type == "isp":
                    is_residential = True
                    is_hosting = False
                    conn_type = "Residential (ISP)"
                elif asn_type == "hosting" or comp_type == "hosting":
                    is_residential = False
                    is_hosting = True
                    conn_type = "Data Center"
                elif asn_type:
                    conn_type = asn_type.capitalize()
    except: pass

    if conn_type == "Unknown" or not org_name:
        try:
            url = f"http://ip-api.com/json/{ip}?fields=status,hosting,proxy,org,isp,as,countryCode,regionName,city"
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=3) as res:
                api_d = json.loads(res.read().decode())
                if conn_type == "Unknown":
                    if api_d.get("hosting"):
                        is_residential = False
                        is_hosting = True
                        conn_type = "Data Center"
                    else:
                        is_residential = True
                        is_hosting = False
                        conn_type = "Residential"
                if not org_name:
                    org_name = api_d.get("as") or api_d.get("org") or api_d.get("isp", "Unknown")
                if not location:
                    location = f"{api_d.get('countryCode', '')} {api_d.get('regionName', '')} {api_d.get('city', '')}".strip()
        except: pass

    return {
        "conn_type": conn_type,
        "is_residential": is_residential,
        "is_hosting": is_hosting,
        "org": org_name or "Unknown",
        "location": location or "Unknown",
        "ipqs_raw": ipqs_data
    }

def evaluate_ip(ip, settings, verbose=False):
    if verbose:
        print("[*] 正在扫描 5 大国际 DNSBL 反滥用黑名单...")
    rbl_res = check_dnsbl(ip)
    
    native_meta = get_native_ip_type(ip, settings)
    is_residential = native_meta["is_residential"]
    conn_type = native_meta["conn_type"]
    org_name = native_meta["org"]

    ab_key = settings.get("abuseipdb_key", "")
    ab_res = check_abuseipdb(ip, ab_key) if ab_key else None
    ipqs_res = native_meta["ipqs_raw"]

    score = 100

    if not is_residential: score -= 15
    if rbl_res.get("Barracuda (恶意攻击/漏洞扫描)"): score -= 25
    if rbl_res.get("SpamCop (垃圾发包/网络滥用)"): score -= 20
    if rbl_res.get("SORBS Combined (综合安全黑名单)"): score -= 15
    if rbl_res.get("DroneBL (公开代理/IRC滥用)"): score -= 10

    if rbl_res.get("Spamhaus ZEN (黑客/肉鸡/PBL)"):
        if is_residential: score -= 5
        else: score -= 20

    if ab_res and "error" not in ab_res:
        ab_score = ab_res.get("score", 0)
        if ab_score > 0: score -= int(ab_score * 0.6)
        if ab_res.get("reports", 0) > 5: score -= 10

    if ipqs_res and "error" not in ipqs_res:
        fraud = ipqs_res.get("fraud_score", 0)
        if fraud > 20: score -= int((fraud - 20) * 0.5)
        if ipqs_res.get("recent_abuse"): score -= 25
        if ipqs_res.get("proxy") or ipqs_res.get("vpn"): score -= 10

    score = max(0, min(100, score))

    if score >= 85: grade, color, desc = "S", C_S, "绝品原生 (原生住宅/顶级信誉)"
    elif score >= 70: grade, color, desc = "A", C_A, "优质中继 (干净机房/未受污染)"
    elif score >= 50: grade, color, desc = "B", C_B, "及格可用 (常规代理/注意验证码)"
    else: grade, color, desc = "C", C_C, "高危劣质 (严重标黑/建议弃用)"

    if verbose:
        print("-----------------------------------------------------------------")
        for name, is_listed in rbl_res.items():
            if is_listed: print(f"  ❌ {name:<35} : [列入黑名单 / 被标记]")
            else: print(f"  ✅ {name:<35} : [正常 / 纯净]")
        print("-----------------------------------------------------------------")

        if ab_res:
            if "error" not in ab_res:
                s_col = "✅" if ab_res['score'] == 0 else ("⚠️" if ab_res['score'] < 30 else "❌")
                print(f"  {s_col} AbuseIPDB 滥用置信分 : {ab_res['score']}% (90天被举报: {ab_res['reports']} 次)")
                print(f"  👉 最近一次被举报案发时间: {ab_res['last_reported']}")
            else: print(f"  [-] AbuseIPDB 查询异常: {ab_res['error']}")
        else: print("  [*] AbuseIPDB : 未配置 API Key (菜单5可配置)")

        if ipqs_res:
            if "error" not in ipqs_res:
                f_col = "✅" if ipqs_res.get('fraud_score', 0) < 30 else ("⚠️" if ipqs_res.get('fraud_score', 0) < 75 else "❌")
                print(f"  {f_col} IPQS 综合欺诈分     : {ipqs_res.get('fraud_score', 0)} / 100")
                print(f"  👉 原生连接类型识别      : {conn_type}")
                print(f"  👉 识别为商业代理/VPN    : {'是' if (ipqs_res.get('proxy') or ipqs_res.get('vpn')) else '否'}")
                print(f"  👉 存在近期活跃恶意行为  : {'是' if ipqs_res.get('recent_abuse') else '否'}")
            else: print(f"  [-] IPQS 查询异常: {ipqs_res.get('error')}")
        else: print("  [*] IPQualityScore : 未配置 API Key (菜单5可配置)")

        print(f"  👉 运营商/组织 (Org)     : {org_name}")
        print(f"  👉 真实网络类型判定      : {'🟢 原生家庭住宅 (Residential)' if is_residential else '🏢 数据中心/机房 (Data Center)'}")
        print("=================================================================")
        print(f"👉 综合风控评分: {score} 分")
        print(f"👉 最终质量评级: {color}[{grade} 级 - {desc}]{C_RESET}")
        print("=================================================================")

    return score, grade, color, desc, native_meta

def ip_quality_audit():
    s = load_settings()
    info = get_current_full_info()
    curr_ip = info.get("query", "")
    if not curr_ip:
        print("\n❌ 无法获取当前公网出站 IP，请检查网络。")
        input("\n按回车键返回菜单..."); return

    main_ip = get_main_ip()
    ip_type = "🔴 [当前出口为 VPS 物理真实 IP]" if curr_ip == main_ip else "🟢 [当前出口为 VPN Gate 代理节点]"

    meta = get_native_ip_type(curr_ip, s)
    loc_display = meta["location"] if meta["location"] != "Unknown" else info.get("location", "Unknown")
    isp_display = meta["org"] if meta["org"] != "Unknown" else info.get("isp", "Unknown")

    print("\n=================================================================")
    print("      🛡️ IP 专业风控与滥用黑名单体检报告 (详细版)")
    print("=================================================================")
    print(f"当前检测目标 IP : {curr_ip} {ip_type}")
    print(f"地理位置归属    : {loc_display}")
    print(f"网络服务商/ASN  : {isp_display}")
    print("-----------------------------------------------------------------")
    evaluate_ip(curr_ip, s, verbose=True)
    input("\n按回车键返回菜单...")

# --- 拨号与节点管理逻辑 ---

def tcp_ping(ip, port, timeout=1.5):
    try:
        st = time.time(); s = socket.create_connection((ip, port), timeout=timeout); s.close()
        return (time.time() - st) * 1000
    except: return 9999.0

def probe_node(node):
    conf = base64.b64decode(node['b64']).decode('utf-8', errors='ignore')
    port = 1194; proto = 'udp'
    for line in conf.splitlines():
        if line.startswith('remote '):
            parts = line.split()
            if len(parts) >= 3:
                try: port = int(parts[2])
                except: pass
        elif line.startswith('proto '):
            if len(line.split()) > 1: proto = line.split()[1].strip()

    ports_to_try = [port] if proto == 'tcp' else []
    for p in [443, 1194, 995]:
        if p not in ports_to_try: ports_to_try.append(p)

    latency = 9999.0
    for p in ports_to_try:
        lat = tcp_ping(node['ip'], p)
        if lat < 9999.0:
            latency = lat; break
    if latency == 9999.0:
        try:
            st = time.time()
            res = subprocess.run(["ping", "-c", "1", "-W", "1", node['ip']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res.returncode == 0: latency = (time.time() - st) * 1000
        except: pass
    return latency

def batch_real_geo_info(ips):
    results = {}
    for i in range(0, len(ips), 90):
        chunk = ips[i:i+90]
        try:
            data = json.dumps([{"query": ip} for ip in chunk]).encode('utf-8')
            req = urllib.request.Request("http://ip-api.com/batch?fields=query,isp,city,regionName", data=data)
            with urllib.request.urlopen(req, timeout=6) as res:
                for item in json.loads(res.read().decode('utf-8')):
                    results[item['query']] = {
                        'isp': item.get('isp', 'Unknown'), 'region': item.get('regionName', ''), 'city': item.get('city', '')
                    }
        except: pass
    return results

def fetch_nodes(target_country, get_asn=False):
    settings = load_settings(); filter_softether = settings.get("filter_softether", True)
    bad_keywords = ["softether", "daiyuu", "academic", "tsukuba", "vpngate", "dncservers"]
    try:
        req = urllib.request.Request(API_URL, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=12) as response: html = response.read().decode('utf-8')
    except: return []

    nodes = []
    target_cc = target_country.strip().upper()
    for row in csv.DictReader([line for line in html.splitlines() if line and not line.startswith("*")]):
        country_short = row.get("CountryShort", "").strip().upper()
        if country_short == target_cc and row.get("OpenVPN_ConfigData_Base64"):
            operator = row.get("Operator", "Unknown")
            if filter_softether and any(k in operator.lower() for k in bad_keywords): continue
            nodes.append({
                'ip': row.get("IP"), 'country': country_short, 'speed': int(row.get("Speed", 0)) / 1000000,
                'operator': operator, 'region': 'Unknown', 'b64': row.get("OpenVPN_ConfigData_Base64")
            })

    nodes.sort(key=lambda x: -x['speed'])
    worker_count = min(len(nodes) or 1, 100)

    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
        future_to_node = {executor.submit(probe_node, n): n for n in nodes}
        for future in concurrent.futures.as_completed(future_to_node):
            future_to_node[future]['ping'] = future.result()

    if get_asn:
        geo_data = batch_real_geo_info([n['ip'] for n in nodes if n['ping'] < 2000.0])
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
        "\n# --- 全局代理与兼容性参数 ---",
        "dev vpngate0", "dev-type tun", "auth-user-pass /etc/vpngate/auth.txt",
        "redirect-gateway def1 bypass-dhcp", "auth-nocache", "resolv-retry infinite", "nobind",
        "data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC:AES-256-CBC",
        "data-ciphers-fallback AES-128-CBC"
    ]
    with open(OVPN_FILE, "w") as f: f.write(raw_config + "\n" + "\n".join(custom_options))

def dial_and_verify(node):
    print(f"[-] 正在尝试拨号: {node['ip']} (TCPing: {node['ping']:.1f}ms)...")
    write_config(node)

    force_clean_routes()
    svc_cmd("start", "vpngate")

    for _ in range(8):
        time.sleep(3)
        info = get_current_full_info()
        curr = info.get("query", "")
        if curr and curr != get_main_ip():
            print(f"[√] 拨号成功！出站IP: `{curr}` | 归属: `{info.get('location', 'Unknown')}` | ASN: `{info.get('isp', 'Unknown')}`")
            s = load_settings()
            s['target_ip'] = curr
            s['daemon_enabled'] = True
            save_settings(s)
            return True

    print(f"[!] {node['ip']} 连接超时或出站IP未生效，安全回退。")
    force_clean_routes()
    return False

def auto_dial(target_country):
    print(f"[-] 自动通道触发：正在并发测速获取 [{target_country}] 最佳出口...")
    nodes = fetch_nodes(target_country, get_asn=False)
    if not nodes:
        print("[!] 暂未抓取到可用节点，物理网络正在恢复...")
        return False
    for node in nodes[:20]:
        if dial_and_verify(node): return True
    return False

# --- 后台守护与看门狗核心 ---

def daemon_process():
    print("[*] VPN Gate 后台自动巡检守护已激活...")
    settings = load_settings()
    target_country = settings.get("country", "JP")
    main_ip = get_main_ip()

    # 1. 开机/启动瞬间：如果未接入 VPN 或进程缺失，0 秒等待立即执行 auto_dial
    curr_info = get_current_full_info()
    curr_ip = curr_info.get("query", "")
    if not curr_ip or curr_ip == main_ip or not is_process_running("openvpn"):
        print("[*] 首次引导检测：VPN 处于未连接状态，立即执行开机极速拨号...")
        force_clean_routes()
        auto_dial(target_country)

    # 2. 常驻循环健康检测
    fail_count = 0
    while True:
        settings = load_settings()
        if settings.get("daemon_enabled", True):
            curr_info = get_current_full_info()
            curr_ip = curr_info.get("query", "")
            target_country = settings.get("country", "JP")

            if not curr_ip or curr_ip == main_ip or not is_process_running("openvpn"):
                fail_count += 1
                if fail_count >= 2:
                    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] 侦测到连接断开或进程异常退出！立即重拨自愈...")
                    force_clean_routes()
                    auto_dial(target_country)
                    fail_count = 0
            else:
                fail_count = 0

        time.sleep(max(10, settings.get("interval", 20)))

# --- 控制菜单 ---

def settings_menu():
    while True:
        s = load_settings()
        daemon_str = '🟢已开启 (含 Crontab+Systemd 双重看门狗)' if s.get('daemon_enabled', True) else '🔴已停用 (看门狗已安全休眠)'
        print(f"\n============= 系统与守护设置 =============")
        print(f" 1. 切换目标国家 [当前: {s.get('country', 'JP')}]")
        print(f" 2. 开/关 后台看门狗与开机自愈 [当前: {daemon_str}]")
        print(f" 3. 开/关 官方/学术节点过滤 [当前: {'🟢已开启' if s.get('filter_softether') else '🔴已停用'}]")
        print(f" 4. 修改守护巡检周期 [当前: {s.get('interval', 20)} 秒]")
        print(f" 5. 配置专业风控 API 密钥 (AbuseIPDB / IPQS / IPinfo)")
        print(f" 6. 重新检测并拉起看门狗服务 (立即健康自检)")
        print(" 0. 返回主菜单")
        print("==========================================")
        c = input("请选择 [0-6]: ").strip()
        if c == '1':
            cc = input("请输入两位国码 (如 HK, JP, US): ").strip().upper()
            if len(cc) == 2: s['country'] = cc; save_settings(s)
        elif c == '2':
            s['daemon_enabled'] = not s.get('daemon_enabled', True); save_settings(s)
            if s['daemon_enabled']:
                svc_cmd("restart", "vpngate-daemon")
                print(f"[√] 双重看门狗已激活！开机自启与进程保活恢复正常。")
            else:
                svc_cmd("stop", "vpngate-daemon")
                print(f"[√] 双重看门狗已停用并挂起，系统不会再自动拉起重拨。")
        elif c == '3':
            s['filter_softether'] = not s.get('filter_softether', True); save_settings(s)
            print(f"[√] 官方/学术节点过滤已{'开启' if s['filter_softether'] else '关闭'}")
        elif c == '4':
            try:
                ni = int(input("请输入周期(秒, 最低10秒): "))
                if ni >= 10: s['interval'] = ni; save_settings(s)
            except: pass
        elif c == '5':
            print("\n--- 配置专业风控密钥 (直接回车保持不变) ---")
            ak = input(f"AbuseIPDB API Key [{s.get('abuseipdb_key', '未配置')}]: ").strip()
            if ak: s['abuseipdb_key'] = ak
            iq = input(f"IPQualityScore API Key [{s.get('ipqs_key', '未配置')}]: ").strip()
            if iq: s['ipqs_key'] = iq
            it = input(f"IPinfo Token [{s.get('ipinfo_token', '未配置')}]: ").strip()
            if it: s['ipinfo_token'] = it
            save_settings(s)
            print("[√] API 密钥配置已更新保存！")
        elif c == '6':
            print("[-] 正在重启并核对看门狗服务状态...")
            svc_cmd("restart", "vpngate-daemon")
            time.sleep(1)
            is_run = is_process_running("vpngate daemon")
            print(f"👉 守护进程 (vpngate daemon) 运行状态: {'🟢 正在运行' if is_run else '❌ 未运行'}")
            input("按回车键继续...")
        elif c == '0': break

def main_menu():
    while True:
        s = load_settings(); curr_cc = s.get('country', 'JP')
        daemon_status = '🟢看门狗守护中' if s.get('daemon_enabled', True) else '🔴守护挂起'
        print(f"\n======== VPN Gate 最终版 1.0 [{curr_cc}] [{daemon_status}] ========")
        print(" 1. 自动智能拨号 (纯连通保底：并发测速并秒连最佳出口)")
        print(" 2. 手动选择节点 (人工决策：支持连接前 S/A/B/C 评级挑选)")
        print(" 3. 停止连接 (主动切断 + 挂起自动看门狗 + 恢复本机出口)")
        print(" 4. 查看当前网络真实状态")
        print(" 5. 系统与设置 (看门狗管理 / 目标国家 / API 密钥管理)")
        print(" 6. 🛡️ IP 专业风控与滥用黑名单体检 (全维度详细报告)")
        print(" 0. 退出面板")
        print("=================================================================")
        c = input("请选择操作 [0-6]: ").strip()

        if c == '1': 
            force_clean_routes()
            auto_dial(curr_cc)
        elif c == '2':
            force_clean_routes()
            print(f"[-] 正在全量并发 TCPing 测速并解析 [{curr_cc}] 地理位置，请稍候...")
            nodes = fetch_nodes(curr_cc, get_asn=True)
            if not nodes: 
                print("[!] 节点列表为空，请检查物理网络。"); continue
            print(f"\n================ [{curr_cc}] 节点列表 (共 {len(nodes)} 个可用) ================")
            print(f" {'ID':<3} | {'IP 地址':<15} | {'Ping':<5} | {'带宽':<5} | {'地区 (Region)':<13} | {'真实 ASN / ISP'}")
            print("------------------------------------------------------------------------------------------------")
            for i, n in enumerate(nodes):
                print(f" [{i+1:<2}] | {n['ip']:<15} | {n['ping']:<4.0f} | {n['speed']:>4.0f}M | {n['region']:<14} | {n['operator']}")
            print("================================================================================================")
            sel = input(f"\n请选择起始节点 ID [1-{len(nodes)} | 0 返回]: ").strip()
            if sel.isdigit() and 1 <= int(sel) <= len(nodes):
                target_node = nodes[int(sel)-1]
                chk = input(f"[*] 是否对节点 [{target_node['ip']}] 进行连接前 IP 质量体检？(y/N) [默认: n]: ").strip().lower()
                if chk == 'y':
                    print(f"[-] 正在评估 {target_node['ip']} 风控等级...")
                    score, grade, color, desc, _ = evaluate_ip(target_node['ip'], s, verbose=False)
                    print(f"👉 评估结果: 综合评分 {score} 分 | 质量评级: {color}[{grade} 级 - {desc}]{C_RESET}")
                    confirm = input("是否继续连接该节点？(Y/n) [默认: y]: ").strip().lower()
                    if confirm == 'n':
                        continue
                dial_and_verify(target_node)
        elif c == '3':
            force_clean_routes()
            s['target_ip'] = ""
            s['daemon_enabled'] = False
            save_settings(s)
            svc_cmd("stop", "vpngate-daemon")
            print("[√] 已主动断开代理，恢复物理直连。自动看门狗已挂起（下次开机或手动拨号时自动恢复）。")
        elif c == '4':
            info = get_current_full_info()
            curr = info.get("query", "")
            main_ip = get_main_ip()
            if not curr:
                print("❌ [警告] 当前网络完全不通！")
            elif curr == main_ip:
                print(f"[*] 当前直连 VPS 本机出口 | IP: {curr} | 归属: {info.get('location', 'Unknown')} | ASN: {info.get('isp', 'Unknown')}")
            else:
                print(f"[√] VPN 正常代理中 | 出站 IP: {curr} | 归属: {info.get('location', 'Unknown')} | 真实 ASN: {info.get('isp', 'Unknown')}")
        elif c == '5': settings_menu()
        elif c == '6': ip_quality_audit()
        elif c == '0': break

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "daemon": daemon_process()
    else: main_menu()
PY_EOF

chmod +x /usr/local/bin/vpngate

if [ "$INIT_SYS" = "systemd" ]; then
    systemctl daemon-reload
    systemctl enable vps-inbound-protect.service >/dev/null 2>&1
    systemctl enable vpngate-daemon.service >/dev/null 2>&1
    systemctl restart vps-inbound-protect.service >/dev/null 2>&1
    systemctl restart vpngate-daemon.service >/dev/null 2>&1
elif [ "$INIT_SYS" = "openrc" ]; then
    rc-update add vps-inbound-protect default >/dev/null 2>&1 || true
    rc-update add vpngate-daemon default >/dev/null 2>&1 || true
    rc-service vps-inbound-protect restart >/dev/null 2>&1 || true
    rc-service vpngate-daemon restart >/dev/null 2>&1 || true
fi

if [ "$INIT_SYS" = "systemd" ]; then
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
elif [ "$INIT_SYS" = "openrc" ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond restart >/dev/null 2>&1 || true
fi

echo "=========================================================="
echo "✅ VPN Gate 最终版 1.0 部署完毕！"
echo "=========================================================="
EOF
bash install_vpngate.sh && rm -f install_vpngate.sh
