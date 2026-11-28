#!/usr/bin/env bash
#
# verify-node-proto.sh — 在节点本机用自带 xray 当客户端，端到端验证协议栈
#
#   REALITY(直连) / WS(直连) / WS(CDN) / XHTTP(直连) / XHTTP(CDN)
#   判定标准：经 socks5 出站访问 https://www.gstatic.com/generate_204 必须返回 204
#
# 用法: sudo bash verify-node-proto.sh [--verbose]
# 说明: 参数全部从 /etc/caddy-xray-hy2/setup.env 与 /usr/local/etc/xray/config.json 读取，
#       脚本不打印任何凭据。--verbose 时打印失败用例的客户端日志尾部。

set -uo pipefail
ENVF="${ENVF:-/etc/caddy-xray-hy2/setup.env}"
XRAY_CFG="${XRAY_CFG:-/usr/local/etc/xray/config.json}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
WORK="$(mktemp -d /tmp/proto-verify.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

[ -r "$ENVF" ] || { echo "❌ 读不到 $ENVF"; exit 2; }
[ -x "$XRAY_BIN" ] || { echo "❌ 找不到 xray: $XRAY_BIN"; exit 2; }

python3 - "$ENVF" "$XRAY_CFG" "$XRAY_BIN" "$WORK" "${1:-}" <<'PY'
import json, os, subprocess, sys, time

envf, srvcfg, xray_bin, work, verbose = sys.argv[1:6]

# ── 解析 setup.env（shell 风格 KEY=VALUE）──
env = {}
for raw in open(envf, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    env[k.strip()] = v

# ── 服务端 flow / serverNames（值不打印）──
flow, server_names = "", []
try:
    cfg = json.load(open(srvcfg, encoding="utf-8"))
    for ib in cfg.get("inbounds", []):
        if str(ib.get("port")) == "443":
            clients = (ib.get("settings") or {}).get("clients") or []
            if clients:
                flow = clients[0].get("flow") or ""
            rs = (ib.get("streamSettings") or {}).get("realitySettings") or {}
            server_names = rs.get("serverNames") or []
except Exception as e:
    print("⚠️ 读取服务端配置失败: %s" % e)

DOMAIN = env["DOMAIN"]
CDN = env.get("CDN_DOMAIN") or ""
SNI = server_names[0] if server_names else DOMAIN
enc = env.get("XRAY_VLESS_ENCRYPTION") or "none"

def out(uuid, addr, port=443, with_flow=False):
    # flow(xtls-rprx-vision) 只对 TCP+REALITY/TLS 有效；WS/XHTTP 带 flow 会被
    # 客户端直接拒绝（"XTLS only supports TLS and REALITY dir"）
    user = {"id": uuid, "encryption": enc}
    if with_flow and flow:
        user["flow"] = flow
    return {"protocol": "vless",
            "settings": {"vnext": [{"address": addr, "port": port, "users": [user]}]}}

def tls(sni, alpn=None):
    t = {"serverName": sni, "fingerprint": "chrome", "allowInsecure": False}
    if alpn:
        t["alpn"] = alpn
    return t

# padding extra 必须与服务端 xhttpSettings.extra 逐字节一致（否则服务端 400），
# 直接取服务端配置里的那份，而不是 setup.env 里的拼接物。
xhttp_extra = {}
try:
    cfg2 = json.load(open(srvcfg, encoding="utf-8"))
    for ib in cfg2.get("inbounds", []):
        if str(ib.get("port")) == str(env.get("XHTTP_PORT") or "8080"):
            xhttp_extra = ((ib.get("streamSettings") or {}).get("xhttpSettings") or {}).get("extra") or {}
except Exception:
    pass
if not xhttp_extra and env.get("XHTTP_EXTRA"):
    try:
        xhttp_extra = json.loads(env["XHTTP_EXTRA"])
    except Exception:
        xhttp_extra = {}

cases = []

# REALITY（直连 443）
c = out(env["XRAY_UUID"], DOMAIN, with_flow=True)
c["streamSettings"] = {"network": "tcp", "security": "reality",
                       "realitySettings": {"fingerprint": "chrome", "serverName": SNI,
                                           "publicKey": env["XRAY_PUBLIC_KEY"],
                                           "shortId": env["XRAY_SHORT_ID"], "spiderX": "/"}}
cases.append(("REALITY", c))

for label, addr in (("WS-直连", DOMAIN), ("WS-CDN", CDN)):
    if not addr:
        continue
    c = out(env["XRAY_WS_UUID"], addr)
    c["streamSettings"] = {"network": "ws", "security": "tls",
                           "tlsSettings": tls(addr, ["http/1.1"]),
                           "wsSettings": {"path": env["WS_PATH"], "host": addr}}
    cases.append((label, c))

for label, addr in (("XHTTP-直连", DOMAIN), ("XHTTP-CDN", CDN)):
    if not addr:
        continue
    c = out(env["XRAY_XHTTP_UUID"], addr)
    xs = {"path": env["XHTTP_PATH"], "host": addr, "mode": "auto"}
    if xhttp_extra:
        xs["extra"] = xhttp_extra
    c["streamSettings"] = {"network": "xhttp", "security": "tls",
                           "tlsSettings": tls(addr), "xhttpSettings": xs}
    cases.append((label, c))

ok = 0
for idx, (name, ob) in enumerate(cases):
    port = 20810 + idx
    cfg = {"log": {"loglevel": "debug" if verbose else "warning"},
           "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": port,
                         "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [ob]}
    path = os.path.join(work, "c%d.json" % idx)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f)

    proc = subprocess.Popen([xray_bin, "run", "-c", path],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(1.5)
    code, err = 0, ""
    try:
        r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            "--connect-timeout", "8", "-m", "20",
                            "--socks5-hostname", "127.0.0.1:%d" % port,
                            "https://www.gstatic.com/generate_204"],
                           capture_output=True, text=True, timeout=30)
        code = int(r.stdout.strip() or 0)
        err = (r.stderr or "").strip().splitlines()[-1:] 
        err = err[0] if err else ""
    except Exception as e:
        err = str(e)
    finally:
        proc.terminate()
        try:
            outtxt = proc.communicate(timeout=5)[0] or ""
        except subprocess.TimeoutExpired:
            proc.kill()
            outtxt = ""

    if code == 204:
        print("  ✅ %-10s 204" % name)
        ok += 1
    else:
        print("  ❌ %-10s %s  %s" % (name, code if code else "ERR", err[:80]))
        if verbose:
            for l in [x for x in outtxt.strip().splitlines() if x.strip()][-10:]:
                print("       " + l[:190])

print("\n结果: %d/%d 通过" % (ok, len(cases)))
sys.exit(0 if ok == len(cases) else 1)
PY
