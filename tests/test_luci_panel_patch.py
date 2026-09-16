#!/usr/bin/env python3
"""LuCI「MRS 延迟面板」补丁的回归测试。

为什么要这个测试：
    oc-luci-panel.rb 靠「字符串锚点」去改 OpenClash 自带的 client.lua / settings.lua /
    controller/openclash.lua。OpenClash 升级后这些锚点可能变样，而 aoxi-package 是
    上游机器人自动同步的 —— 一旦锚点失配，补丁会在首次开机时静默失败，
    症状是「刷完固件，LuCI 里根本没有 MRS 面板入口」。

这个测试用 OpenClash 真实源码片段当 fixture（tests/fixtures/luci/）跑一遍补丁，
断言：
    1. 三处锚点都还匹配；
    2. 关键的 uci 回写值被改成目录名（上游写 string.lower(面板名)，对 MRSPanel
       会存成 "mrspanel"，而目录是 "mrs-panel"，「设为默认面板」就会无效）；
    3. 重复执行 install 不会重复打补丁（幂等）；
    4. 两个带 OpenClash 的变体都把 aoxi-package 固定到已实测的提交，
       保证锚点验证结果长期有效。

fixture 重新生成方法（从已固定的 aoxi-package 提交取真实文件，保持 tab 原样）：
    SHA=$(grep AOXI_PACKAGE_COMMIT build/Lean_x86_64/custom.sh | cut -d'"' -f2)
    B=https://raw.githubusercontent.com/aoxijy/aoxi-package/$SHA/luci-app-openclash/luasrc
    curl -sL $B/model/cbi/openclash/client.lua  -o /tmp/up-client.lua
    curl -sL $B/model/cbi/openclash/settings.lua -o /tmp/up-settings.lua
    curl -sL $B/controller/openclash.lua        -o /tmp/up-controller.lua
    # 然后各截取锚点前后几行写入 tests/fixtures/luci/
"""

from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "luci"
# 带 OpenClash 的变体（J-Box 变体不含 OpenClash，不需要打补丁）
TARGETS = ("Lean_x86_64", "Lean_x86_64_Docker")
PATCHER_REL = "sources/etc/openclash/custom/oc-luci-panel.rb"

# 关键断言串
NEEDLES = {
    "client.lua": ["MRS-PANEL-PATCH", 'm:append(Template("openclash/mrs_panel"))'],
    "settings.lua": ['"MRSPanel"', 'o.template = "openclash/mrs_panel_setting"'],
    "openclash.lua": [
        '["mrs-panel"] = fs.isdirectory("/usr/share/openclash/ui/mrs-panel")',
        'MRSPanel = "mrs-panel"',
        # 这条就是本次修掉的 bug：必须写目录名，不能写 string.lower(面板名)
        'uci:set("openclash", "config", "default_dashboard", dash_dir)',
    ],
}
FORBIDDEN = {
    "openclash.lua": ['uci:set("openclash", "config", "default_dashboard", string.lower(default_dashboard))'],
}


def fail(message: str) -> None:
    raise AssertionError(message)


def check_variant_pin() -> None:
    pins = {}
    for name in TARGETS:
        custom = ROOT / "build" / name / "custom.sh"
        if not custom.is_file():
            fail(f"{name}: 缺少 custom.sh")
        text = custom.read_text(encoding="utf-8")
        m = re.search(r'^AOXI_PACKAGE_COMMIT="([0-9a-f]{40})"$', text, re.M)
        if not m:
            fail(f"{name}: aoxi-package 未固定到 40 位提交（master 会漂，锚点验证会失效）")
        if "checkout --detach" not in text or "rev-parse HEAD" not in text:
            fail(f"{name}: 固定提交后缺少 checkout --detach / rev-parse 校验")
        pins[name] = m.group(1)
        patcher = ROOT / "build" / name / PATCHER_REL
        if not patcher.is_file():
            fail(f"{name}: 缺少 {PATCHER_REL}")
        ptext = patcher.read_text(encoding="utf-8")
        for key in ("OC_PANEL_TPL", "dash_dir"):
            if key not in ptext:
                fail(f"{name}: oc-luci-panel.rb 缺少 {key}（补丁脚本被改坏了？）")
    if len(set(pins.values())) != 1:
        fail(f"两个变体的 aoxi-package 提交不一致: {pins}")


def run_patch(ruby: str, variant: str) -> None:
    patcher = ROOT / "build" / variant / PATCHER_REL
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "view" / "openclash").mkdir(parents=True)
        (root / "cbi" / "openclash").mkdir(parents=True)
        (root / "ctl").mkdir(parents=True)
        # fixture 按补丁脚本期望的路径摆放
        shutil.copy(FIXTURES / "client.lua", root / "cbi" / "openclash" / "client.lua")
        shutil.copy(FIXTURES / "settings.lua", root / "cbi" / "openclash" / "settings.lua")
        shutil.copy(FIXTURES / "controller.lua", root / "ctl" / "openclash.lua")

        env = dict(os.environ)
        env.update(
            OC_PANEL_TPL=str(ROOT / "build" / variant / "sources/etc/openclash/custom/luci"),
            OC_PANEL_VIEW=str(root / "view" / "openclash"),
            OC_PANEL_CBI=str(root / "cbi" / "openclash"),
            OC_PANEL_CTL=str(root / "ctl" / "openclash.lua"),
        )
        for attempt in (1, 2):  # 第二次验证幂等
            proc = subprocess.run(
                [ruby, str(patcher), "install"],
                env=env,
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                fail(f"{variant}: 第 {attempt} 次 install 失败: {proc.stdout}{proc.stderr}")

        targets = {
            "client.lua": root / "cbi" / "openclash" / "client.lua",
            "settings.lua": root / "cbi" / "openclash" / "settings.lua",
            "openclash.lua": root / "ctl" / "openclash.lua",
        }
        for label, path in targets.items():
            content = path.read_text(encoding="utf-8")
            for needle in NEEDLES[label]:
                if needle not in content:
                    fail(f"{variant}: {label} 缺少预期内容: {needle}")
            for bad in FORBIDDEN.get(label, []):
                if bad in content:
                    fail(f"{variant}: {label} 仍保留上游写法（会导致默认面板失效）: {bad}")
        # 幂等：补丁标记只应出现一次
        for label, marker in (("client.lua", "MRS-PANEL-PATCH"), ("openclash.lua", '["mrs-panel"] = fs.isdirectory')):
            content = targets[label].read_text(encoding="utf-8")
            if content.count(marker) != 1:
                fail(f"{variant}: {label} 的 {marker} 出现 {content.count(marker)} 次，非幂等")


def main() -> int:
    if not FIXTURES.is_dir():
        fail(f"缺少 fixture 目录 {FIXTURES}")
    for name in ("client.lua", "settings.lua", "controller.lua"):
        if not (FIXTURES / name).is_file():
            fail(f"缺少 fixture {name}")

    check_variant_pin()

    ruby = shutil.which("ruby")
    if ruby is None:
        print("SKIP: 未找到 ruby，跳过补丁预演（只做了固定提交与文件检查）")
        print("LUCI_PANEL_PATCH_OK")
        return 0

    for variant in TARGETS:
        run_patch(ruby, variant)

    print("LUCI_PANEL_PATCH_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
