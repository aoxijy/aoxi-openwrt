#!/bin/sh
# 离线测试 oc-panel-secret.sh：生成随机凭据 + 注入 MRS 面板
#
# 用打桩的 uci（tests 里现写）跑一遍真实脚本，验证：
#   1. dashboard_password 为空时会生成 12 位随机串
#   2. 代理认证已启用且密码为空时会生成随机密码
#   3. 密钥被注入面板，占位符 __MRS_SECRET__ 不再出现
#   4. 重复执行幂等（不会反复 set，面板内容不变）
#   5. --inject-only 只注入、不改 uci
#
# 用法: sh tests/test_panel_secret.sh [变体名...]

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS="${*:-Lean_x86_64 Lean_x86_64_Docker}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for T in $TARGETS; do
    SRC="$ROOT/build/$T/sources/etc/openclash/custom/oc-panel-secret.sh"
    PANEL_SRC="$ROOT/build/$T/sources/usr/share/openclash/ui/mrs-panel/index.html"
    [ -f "$SRC" ] || fail "$T: 缺少 oc-panel-secret.sh"
    [ -f "$PANEL_SRC" ] || fail "$T: 缺少面板 index.html"

    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
    STATE="$TMP/state"
    : > "$STATE"

    # ---- 打桩的 uci ----
    cat > "$TMP/bin/uci" <<'STUB'
#!/bin/sh
STATE="${STUB_STATE:-/tmp/stub-state}"
[ "$1" = "-q" ] && shift
cmd="$1"; shift
case "$cmd" in
  get)
    case "$1" in
      openclash.config.dashboard_password) sed -n 's/^dashboard_password=//p' "$STATE" ;;
      'openclash.@authentication[0].enabled') echo 1 ;;
      'openclash.@authentication[0].password') sed -n 's/^auth_password=//p' "$STATE" ;;
      'openclash.@authentication[0].username') echo Clash ;;
    esac
    ;;
  set)
    kv="$1"; k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      openclash.config.dashboard_password) echo "dashboard_password=$v" >> "$STATE" ;;
      'openclash.@authentication[0].password') echo "auth_password=$v" >> "$STATE" ;;
    esac
    ;;
  commit) : ;;
esac
exit 0
STUB
    chmod +x "$TMP/bin/uci"
    export STUB_STATE="$STATE"

    cp "$PANEL_SRC" "$TMP/panel.html"

    # ---- 第一次运行：应当生成两个凭据并注入 ----
    OC_UCI="$TMP/bin/uci" OC_PANEL_HTML="$TMP/panel.html" sh "$SRC" > "$TMP/out1" 2>&1 \
        || fail "$T: 首次执行失败: $(cat "$TMP/out1")"

    DPW="$(sed -n 's/^dashboard_password=//p' "$STATE")"
    APW="$(sed -n 's/^auth_password=//p' "$STATE")"
    [ -n "$DPW" ] || fail "$T: 没有生成 dashboard_password"
    [ -n "$APW" ] || fail "$T: 没有生成代理认证密码"
    for v in "$DPW" "$APW"; do
        case "$v" in
            *[!A-Za-z0-9]*) fail "$T: 生成的凭据含非字母数字字符: $v" ;;
        esac
        [ "${#v}" -eq 12 ] || fail "$T: 凭据长度应为 12，实际 ${#v}（$v）"
    done
    [ "$DPW" != "$APW" ] || fail "$T: 两个凭据不该相同"

    grep -q "^const INJ = '$DPW';" "$TMP/panel.html" \
        || fail "$T: 面板里没有注入正确的密钥"
    if grep -q '__MRS_SECRET__' "$TMP/panel.html"; then
        fail "$T: 面板里仍残留 __MRS_SECRET__ 占位符"
    fi

    # ---- 第二次运行：幂等（不再 set，面板不变）----
    SUM1="$(md5sum "$TMP/panel.html" | cut -d' ' -f1)"
    SETS1="$(grep -c '^dashboard_password=\|^auth_password=' "$STATE")"
    OC_UCI="$TMP/bin/uci" OC_PANEL_HTML="$TMP/panel.html" sh "$SRC" > "$TMP/out2" 2>&1 \
        || fail "$T: 第二次执行失败: $(cat "$TMP/out2")"
    SUM2="$(md5sum "$TMP/panel.html" | cut -d' ' -f1)"
    SETS2="$(grep -c '^dashboard_password=\|^auth_password=' "$STATE")"
    [ "$SETS1" = "$SETS2" ] || fail "$T: 重复执行又写了 uci（$SETS1 -> $SETS2）"
    [ "$SUM1" = "$SUM2" ] || fail "$T: 重复执行改变了面板内容"

    # ---- --inject-only：只注入，不写 uci ----
    cp "$PANEL_SRC" "$TMP/panel.html"
    OC_UCI="$TMP/bin/uci" OC_PANEL_HTML="$TMP/panel.html" sh "$SRC" --inject-only > "$TMP/out3" 2>&1 \
        || fail "$T: --inject-only 执行失败: $(cat "$TMP/out3")"
    SETS3="$(grep -c '^dashboard_password=\|^auth_password=' "$STATE")"
    [ "$SETS1" = "$SETS3" ] || fail "$T: --inject-only 不该写 uci（$SETS1 -> $SETS3）"
    grep -q "^const INJ = '$DPW';" "$TMP/panel.html" || fail "$T: --inject-only 没有注入密钥"

    # ---- 密钥为空时 --inject-only 应安静退出，不能写出空密钥 ----
    cp "$PANEL_SRC" "$TMP/panel.html"
    : > "$STATE"
    OC_UCI="$TMP/bin/uci" OC_PANEL_HTML="$TMP/panel.html" sh "$SRC" --inject-only > "$TMP/out4" 2>&1 \
        || fail "$T: 空密钥时 --inject-only 失败: $(cat "$TMP/out4")"
    grep -q "__MRS_SECRET__" "$TMP/panel.html" || fail "$T: 空密钥时不该改动面板"

    rm -rf "$TMP"
    echo "  ✓ $T"
done

echo "PANEL_SECRET_OK"
