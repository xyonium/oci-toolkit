#!/usr/bin/env bash
#
# test-init-firewall.sh — init-firewall.sh 的 dry-run 测试
#
# 全部用 --local --dry-run，只生成规则文本，绝不调用 nft/sudo/ssh，可以在任何机器上跑。
# 唯一的例外是 nft -c 语法校验：需要 CAP_NET_ADMIN，没有权限时自动跳过。
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT=./init-firewall.sh
BASELINE=./dsh-firewall.nft          # 现网在跑的规则，作为默认 profile 的黄金样本
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

PASS=0
FAIL=0
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }
ok()   { pass; echo "[ ok ] $*"; }

# 断言生成文件包含/不包含某字符串
assert_contains() { # <文件> <字符串> <说明>
    if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3：应包含 [$2]，实际没有"; fi
}
assert_not_contains() { # <文件> <字符串> <说明>
    if grep -qF -- "$2" "$1"; then fail "$3：不应包含 [$2]，实际有"; else ok "$3"; fi
}

# 干跑一次，把 dry-run 输出里的 nft 规则剥出来存成 $OUT/<name>.nft
# 只认第一行 "    #!/usr/sbin/nft -f" 之后的内容，前面的横幅摘要一律丢掉。
gen() { # <名称> [参数...]
    local name="$1"; shift
    local rc=0
    "$SCRIPT" --local --dry-run "$@" > "$OUT/$name.raw" 2>&1 || rc=$?
    awk '/^    #!\/usr\/sbin\/nft/{f=1} f{sub(/^    /,"");print}' "$OUT/$name.raw" > "$OUT/$name.nft"
    return "$rc"
}

# ---------------------------------------------------------------------------
# 0. 静态检查
# ---------------------------------------------------------------------------
if bash -n "$SCRIPT"; then ok "bash -n 语法检查"; else fail "bash -n 未通过"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$SCRIPT"; then ok "shellcheck"; else fail "shellcheck 未通过"; fi
else
    echo "[skip] shellcheck 未安装"
fi

# ---------------------------------------------------------------------------
# 1. 默认 profile 必须与现网 dsh-firewall.nft 逐条一致
#    这是最关键的一条：老机器重跑脚本不能有任何规则变化。
# ---------------------------------------------------------------------------
gen default
grep -v '^[[:space:]]*#' "$BASELINE" | grep -v '^[[:space:]]*$' > "$OUT/baseline.norm"
grep -v '^[[:space:]]*#' "$OUT/default.nft" | grep -v '^[[:space:]]*$' > "$OUT/default.norm"
if diff -u "$OUT/baseline.norm" "$OUT/default.norm" > "$OUT/default.diff" 2>&1; then
    ok "默认 profile 与现网 $BASELINE 逐条一致（重跑为 no-op）"
else
    fail "默认 profile 与现网规则不一致："
    sed 's/^/       /' "$OUT/default.diff" >&2
fi

# ---------------------------------------------------------------------------
# 2. 四个 profile 的端口集合
# ---------------------------------------------------------------------------
gen proxy --profile proxy
assert_contains     "$OUT/proxy.nft" 'tcp dport 80 ct state new accept'   "proxy 放行 80/tcp"
assert_contains     "$OUT/proxy.nft" 'tcp dport 443 ct state new accept'  "proxy 放行 443/tcp"
assert_contains     "$OUT/proxy.nft" 'udp dport 443 accept'               "proxy 放行 443/udp"
assert_contains     "$OUT/proxy.nft" 'udp dport 8443 accept'              "proxy 放行 8443/udp"
assert_contains     "$OUT/proxy.nft" 'udp dport 20000-30000 accept'       "proxy 放行端口跳跃"

gen hy2 --profile hy2
assert_not_contains "$OUT/hy2.nft" 'tcp dport 80 '                        "hy2 不放行 80/tcp"
assert_not_contains "$OUT/hy2.nft" 'tcp dport 443 '                       "hy2 不放行 443/tcp"
assert_not_contains "$OUT/hy2.nft" 'udp dport 443 '                       "hy2 不放行 443/udp"
assert_contains     "$OUT/hy2.nft" 'udp dport 8443 accept'                "hy2 放行 8443/udp"
assert_contains     "$OUT/hy2.nft" 'udp dport 20000-30000 accept'         "hy2 放行端口跳跃"

gen web --profile web
assert_contains     "$OUT/web.nft" 'tcp dport 443 ct state new accept'    "web 放行 443/tcp"
assert_contains     "$OUT/web.nft" 'udp dport 443 accept'                 "web 默认放行 443/udp"
assert_not_contains "$OUT/web.nft" 'udp dport 8443 '                      "web 不放行 hy2"
assert_not_contains "$OUT/web.nft" '20000-30000'                          "web 不放行端口跳跃"

gen minimal --profile minimal
assert_contains     "$OUT/minimal.nft" 'tcp dport 22 ct state new accept' "minimal 只放 SSH"
assert_not_contains "$OUT/minimal.nft" 'dport 80 '                        "minimal 不放行 80"
assert_not_contains "$OUT/minimal.nft" 'dport 443 '                       "minimal 不放行 443"
assert_not_contains "$OUT/minimal.nft" '8443'                             "minimal 不放行 hy2"

# ---------------------------------------------------------------------------
# 3. 端口/范围开关
# ---------------------------------------------------------------------------
gen sshport --profile minimal --ssh-port 26320
assert_contains     "$OUT/sshport.nft" 'tcp dport 26320 ct state new accept' "--ssh-port 生效"
assert_not_contains "$OUT/sshport.nft" 'tcp dport 22 '                       "--ssh-port 后不再放行 22"

gen hy2port --profile hy2 --hy2-port 9443
assert_contains     "$OUT/hy2port.nft" 'udp dport 9443 accept'  "--hy2-port 生效"
assert_not_contains "$OUT/hy2port.nft" 'udp dport 8443 '        "--hy2-port 后不再放行 8443"

gen nohop --profile hy2 --no-hy2-hop
assert_not_contains "$OUT/nohop.nft" '20000-30000'              "--no-hy2-hop 关掉跳跃范围"

gen customhop --profile hy2 --hy2-hop 30000-40000
assert_contains     "$OUT/customhop.nft" 'udp dport 30000-40000 accept' "--hy2-hop 自定义范围生效"

gen nohttp3 --profile web --no-http3
assert_not_contains "$OUT/nohttp3.nft" 'udp dport 443 '         "--no-http3 关掉 443/udp"

gen frps --profile minimal --enable-frps
assert_contains     "$OUT/frps.nft" 'tcp dport 7102 ct state new accept' "frps TCP 放行"
assert_contains     "$OUT/frps.nft" 'udp dport 7001 accept'              "frps UDP 7001 放行"

gen xmpp --profile minimal --enable-xmpp
assert_contains     "$OUT/xmpp.nft" 'tcp dport 5222 ct state new accept' "XMPP 放行"

gen noflags --profile minimal
assert_not_contains "$OUT/noflags.nft" '7102'                   "默认不开 frps"
assert_not_contains "$OUT/noflags.nft" '5222'                   "默认不开 XMPP"

# ---------------------------------------------------------------------------
# 4. 额外端口（可重复、逗号/空格分隔、区间）
# ---------------------------------------------------------------------------
gen extra --profile minimal --extra-tcp 8080,9090 --extra-tcp '9000-9100' --extra-udp 53
assert_contains     "$OUT/extra.nft" 'tcp dport { 8080, 9090 } ct state new accept'  "--extra-tcp 逗号列表"
assert_contains     "$OUT/extra.nft" 'tcp dport { 9000-9100 } ct state new accept'   "--extra-tcp 重复使用"
assert_contains     "$OUT/extra.nft" 'udp dport { 53 } accept'                       "--extra-udp"
gen extraspace --profile minimal --extra-tcp '8080 9090'
assert_contains     "$OUT/extraspace.nft" 'tcp dport { 8080, 9090 } ct state new accept' "--extra-tcp 空格分隔"

# ---------------------------------------------------------------------------
# 5. 安全不变式：任何 profile/开关组合都不能丢掉 REJECT 兜底
# ---------------------------------------------------------------------------
for f in default proxy hy2 web minimal extra frps xmpp nohop nohttp3; do
    t="$OUT/$f.nft"
    if ! grep -qx '    reject' "$t"; then
        fail "$f 缺少兜底 reject"; continue
    fi
    # reject 必须是 input 链的最后一条：下一行只能是 chain 的收尾 "  }"
    nxt="$(grep -A1 -x '    reject' "$t" | sed -n '2p')"
    if [ "$nxt" = "  }" ]; then ok "$f 白名单后仍有 REJECT 兜底"; else fail "$f 的 reject 不在链尾（下一行是 '$nxt'）"; fi
    assert_contains "$t" 'ip6 nexthdr udp reject with icmpv6 port-unreachable' "$f 有 v6 兜底"
done

# ---------------------------------------------------------------------------
# 6. 非法输入必须 exit 2，且绝不产出半份规则
# ---------------------------------------------------------------------------
bad() { # <说明> [参数...]
    local desc="$1"; shift
    local rc=0
    "$SCRIPT" --local --dry-run "$@" > "$OUT/bad.raw" 2>&1 || rc=$?
    if [ "$rc" -ne 2 ]; then fail "$desc：期望 exit 2，实际 $rc"; return; fi
    if awk '/^    #!\/usr\/sbin\/nft/{f=1} f' "$OUT/bad.raw" | grep -q .; then
        fail "$desc：报错后仍输出了 nft 规则"; return
    fi
    ok "拒绝 $desc（exit 2，无规则输出）"
}
bad "端口表达式注入"   --extra-tcp '443 accept;'
bad "端口越界"         --extra-tcp 70000
bad "区间前后颠倒"     --extra-tcp 9100-9000
bad "跳跃范围非法"     --hy2-hop abc
bad "SSH 端口为 0"     --ssh-port 0
bad "SSH 端口超界"     --ssh-port 99999
bad "SSH 端口非数字"   --ssh-port abc
bad "hy2 端口非数字"   --hy2-port 8x
bad "未知 profile"     --profile nosuch
bad "未知选项"         --bogus-flag

missing() { # <选项> —— 缺参数也必须是 exit 2
    local rc=0
    "$SCRIPT" --local "$1" > "$OUT/miss.raw" 2>&1 || rc=$?
    if [ "$rc" -ne 2 ]; then fail "$1 缺参数：期望 exit 2，实际 $rc"; else ok "$1 缺参数报错"; fi
}
for opt in --profile --ssh-port --hy2-port --hy2-hop --extra-tcp --extra-udp; do missing "$opt"; done

# 没有主机也没 --local
rc=0; "$SCRIPT" > "$OUT/nohost.raw" 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then fail "既无主机也无 --local 应 exit 2，实际 $rc"; else ok "既无主机也无 --local 时报错"; fi

# ---------------------------------------------------------------------------
# 7. 远程 dry-run 不得发起任何网络操作（给一个必然解析失败的主机名）
# ---------------------------------------------------------------------------
timeout 15 "$SCRIPT" user@invalid.invalid --dry-run > "$OUT/remote.raw" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "远程 dry-run 期望 exit 0，实际 $rc"
elif grep -q 'ssh\|scp' "$OUT/remote.raw" && grep -qi 'connection\|refused\|resolve' "$OUT/remote.raw"; then
    fail "远程 dry-run 试图联网"
else
    ok "远程 dry-run 只打印规则、不联网"
fi

# ---------------------------------------------------------------------------
# 8. nft 语法校验（可选：需要 CAP_NET_ADMIN，普通用户下自动跳过）
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    NFT="nft"; [ "$(id -u)" -eq 0 ] || NFT="sudo -n nft"
    for f in default proxy hy2 web minimal extra frps xmpp; do
        if $NFT -c -f "$OUT/$f.nft" 2>"$OUT/nfterr"; then ok "nft -c 通过：$f"
        else fail "nft -c 失败：$f"; sed 's/^/       /' "$OUT/nfterr" >&2; fi
    done
else
    echo "[skip] nft -c 需要 root/CAP_NET_ADMIN（远端 --apply 时会先跑 nft -c -f 再加载）"
fi

# ---------------------------------------------------------------------------
echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
