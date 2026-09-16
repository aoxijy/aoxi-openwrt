#!/bin/sh
# oc-panel-secret.sh —— 凭据自愈 + 把密钥填进 MRS 面板
#
# 为什么需要它：
#   固件仓库是公开的（Releases 也是公开的），所以镜像里**不能带任何固定凭据**。
#   于是仓库里的 /etc/config/openclash 把 dashboard_password 和
#   @authentication[0].password 都留空，由本脚本在设备上生成随机值：
#     · dashboard_password      → mihomo 的 secret，MRS 面板/脚本调 API 要用
#     · authentication.password → SOCKS5/HTTP(S) 代理认证（仅在该项启用时）
#   生成后再把值填进 /usr/share/openclash/ui/mrs-panel/index.html 的占位符，
#   这样面板打开就是能用的，用户不用手抄密钥。
#
# 调用点：
#   · /etc/uci-defaults/97-openclash-mrs  首启（保证首次启动核心前密钥已存在）
#   · openclash_custom_overwrite.sh       每次生成运行配置时（自愈 + 保持面板同步）
#
# 用法：
#   oc-panel-secret.sh              生成缺失的凭据 + 注入面板
#   oc-panel-secret.sh --inject-only 只注入面板（不改 uci）

# 面板路径 / uci 命令都可以用环境变量覆盖，便于离线自测（见 tests/test_panel_secret.sh）
PANEL="${OC_PANEL_HTML:-/usr/share/openclash/ui/mrs-panel/index.html}"
UCI="${OC_UCI:-uci}"

rand_str() {
    # 优先 /dev/urandom；取不到就退化成时间+pid（仍然每台设备不同）
    s="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12)"
    [ -n "$s" ] || s="$(date +%s)$RANDOM$$"
    printf '%s' "$s" | cut -c1-12
}

ensure_credentials() {
    changed=0

    cur="$("$UCI" -q get openclash.config.dashboard_password)"
    if [ -z "$cur" ]; then
        new="$(rand_str)"
        if [ -n "$new" ]; then
            "$UCI" -q set openclash.config.dashboard_password="$new" && changed=1
            echo "[oc-secret] 已生成随机的 Clash API 密钥（dashboard_password），可在 OpenClash 设置里查看/修改"
        fi
    fi

    # 代理认证：只在「已启用」且密码为空时补一个随机密码，不主动开启该功能
    aen="$("$UCI" -q get openclash.@authentication[0].enabled)"
    apw="$("$UCI" -q get openclash.@authentication[0].password)"
    if [ "$aen" = "1" ] && [ -z "$apw" ]; then
        new="$(rand_str)"
        if [ -n "$new" ]; then
            "$UCI" -q set openclash.@authentication[0].password="$new" && changed=1
            echo "[oc-secret] 已生成随机的代理认证密码（用户名 $("$UCI" -q get openclash.@authentication[0].username)），可在 OpenClash 设置里查看"
        fi
    fi

    [ "$changed" = "1" ] && "$UCI" -q commit openclash
    return 0
}

inject_panel() {
    [ -f "$PANEL" ] || return 0
    sec="$("$UCI" -q get openclash.config.dashboard_password)"
    [ -n "$sec" ] || return 0
    # 只改 `const INJ = '...';` 这一行（面板优先使用它，其次才是浏览器里存的值）
    grep -q "^const INJ = " "$PANEL" 2>/dev/null || return 0
    awk -v s="$sec" -v q="'" \
        '/^const INJ = / { print "const INJ = " q s q ";"; next } { print }' \
        "$PANEL" > "$PANEL.tmp" 2>/dev/null && mv "$PANEL.tmp" "$PANEL" 2>/dev/null
    return 0
}

case "$1" in
    --inject-only) inject_panel ;;
    *) ensure_credentials; inject_panel ;;
esac
exit 0
