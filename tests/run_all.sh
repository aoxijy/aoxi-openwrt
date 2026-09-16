#!/bin/sh
# 仓库自检总入口 —— 固件编译前跑一遍，任何一项失败都应当阻断编译。
#
# 覆盖的问题（都是实际踩过的坑）：
#   · J-Box 变体混进 OpenClash          → tests/test_jbox_targets.py
#   · 公开镜像里带固定凭据（密钥泄露）   → tests/test_no_credentials.py
#   · OpenClash 升级后 LuCI 补丁锚点失配 → tests/test_luci_panel_patch.py
#   · 面板密钥生成/注入逻辑坏掉          → tests/test_panel_secret.sh
#
# 用法: sh tests/run_all.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

note() { printf '  %s\n' "$*"; }

run_py() {
    desc="$1"; file="$2"
    if [ ! -f "$ROOT/$file" ]; then
        note "✗ $desc: 找不到 $file"
        FAILED=1
        return
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        note "! 跳过 $desc（没有 python3）"
        return
    fi
    if python3 "$ROOT/$file"; then
        note "✓ $desc"
    else
        note "✗ $desc"
        FAILED=1
    fi
}

run_sh() {
    desc="$1"; file="$2"
    if [ ! -f "$ROOT/$file" ]; then
        note "✗ $desc: 找不到 $file"
        FAILED=1
        return
    fi
    if sh "$ROOT/$file"; then
        note "✓ $desc"
    else
        note "✗ $desc"
        FAILED=1
    fi
}

echo "== 固件仓库自检 =="

# test_jbox_targets.py 依赖 PyYAML；缺了就跳过，不要让环境问题把编译卡死
if python3 -c 'import yaml' >/dev/null 2>&1; then
    run_py "J-Box 契约（不含 OpenClash / 固定 aoxi-package 提交）" tests/test_jbox_targets.py
else
    note "! 跳过 J-Box 契约测试（缺 python3-yaml：pip install pyyaml）"
fi

run_py "公开镜像不含固定凭据" tests/test_no_credentials.py
run_py "LuCI MRS 面板补丁锚点 + 幂等" tests/test_luci_panel_patch.py
run_sh "面板密钥生成/注入" tests/test_panel_secret.sh

if [ "$FAILED" = "0" ]; then
    echo "== 自检通过 =="
    exit 0
fi
echo "== 自检未通过，已阻止编译 ==" >&2
exit 1
