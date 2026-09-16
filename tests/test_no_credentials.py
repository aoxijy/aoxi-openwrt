#!/usr/bin/env python3
"""公开镜像不得携带固定凭据 —— 回归测试。

背景（真实事故）：
    固件仓库和 Releases 都是公开的。第一版把路由器上的 etc/config/openclash 直接
    搬进了仓库，于是两处凭据被公开：
        · option dashboard_password '<12位>'   → mihomo API 的 Bearer secret
        · config authentication / option password '<8位>' → SOCKS5/HTTP 代理认证密码
    后果：所有刷了这个固件的设备共用一份写在 GitHub 上的密钥，局域网内任何设备
    都能用公开的密码调 API、用代理。

现在的做法：
    · 仓库里的 etc/config/openclash 把这两项留空；
    · 设备首次开机由 oc-panel-secret.sh 生成设备专属随机值；
    · 生成后写进 MRS 面板，用户不用手抄；用户改过密码后由覆写钩子重新同步。

这个测试扫描所有会被打进镜像的文件，确保：
    1. 没有非空的 dashboard_password / 代理认证密码 / yml 里的 secret；
    2. 没有出现已知的旧密码字面量；
    3. 面板里用的是 __MRS_SECRET__ 占位符，而不是硬编码密钥；
    4. 生成密钥的脚本存在，且首启脚本与覆写钩子都调用了它。
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("Lean_x86_64", "Lean_x86_64_Docker")   # 带 OpenClash 的变体
JBOX_TARGETS = ("Lean_x86_64_JBox", "Lean_x86_64_JBox_Docker")
# 曾经误提交过的旧凭据，出现即失败
KNOWN_LEAKS = ("CLJblvhE", "CKOjq4Fz")
PLACEHOLDER = "__MRS_SECRET__"
PANEL_REL = "sources/usr/share/openclash/ui/mrs-panel/index.html"
SECRET_SH = "sources/etc/openclash/custom/oc-panel-secret.sh"
HOOK_REL = "sources/etc/openclash/custom/openclash_custom_overwrite.sh"
FIRSTBOOT_REL = "sources/etc/uci-defaults/97-openclash-mrs"


def fail(message: str) -> None:
    raise AssertionError(message)


def shipped_files(target: str):
    for base in (ROOT / "build" / target / "sources", ROOT / "build" / target / "files"):
        if base.is_dir():
            yield from (p for p in base.rglob("*") if p.is_file())


def check_no_plaintext(target: str) -> None:
    for path in shipped_files(target):
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        rel = path.relative_to(ROOT / "build" / target)
        for leak in KNOWN_LEAKS:
            if leak in text:
                fail(f"{target}/{rel}: 仍包含已知泄露的凭据 {leak}")

        if path.name == "openclash" and "config config" in text:
            for m in re.finditer(r"^\s*option\s+(dashboard_password|password)\s+'([^']*)'", text, re.M):
                key, value = m.group(1), m.group(2)
                if value:
                    fail(f"{target}/{rel}: {key} 不能是非空固定值（公开仓库会泄露），应留空并由设备随机生成")

        if path.suffix in (".yaml", ".yml") or path.name.startswith("zhu"):
            m = re.search(r"^secret:\s*(\S+)", text, re.M)
            if m:
                fail(f"{target}/{rel}: 配置里带明文 secret")


def check_panel_placeholder(target: str) -> None:
    panel = ROOT / "build" / target / PANEL_REL
    if not panel.is_file():
        fail(f"{target}: 缺少 MRS 面板 {PANEL_REL}")
    text = panel.read_text(encoding="utf-8")
    if PLACEHOLDER not in text:
        fail(f"{target}: 面板里没有 {PLACEHOLDER} 占位符，密钥无法自动注入")
    m = re.search(r"^const INJ = '([^']*)';", text, re.M)
    if not m:
        fail(f"{target}: 面板里找不到 `const INJ = '...';` 那一行")
    if m.group(1) != PLACEHOLDER:
        fail(f"{target}: 面板 INJ 应为 {PLACEHOLDER}，实际是 {m.group(1)!r}（疑似硬编码密钥）")
    if "INJECTED ||" not in text:
        fail(f"{target}: 面板应让注入的密钥优先于浏览器本地保存的值")


def check_generator_wired(target: str) -> None:
    secret_sh = ROOT / "build" / target / SECRET_SH
    if not secret_sh.is_file():
        fail(f"{target}: 缺少 {SECRET_SH}")
    body = secret_sh.read_text(encoding="utf-8")
    for needle in ("dashboard_password", "@authentication[0].password", "inject_panel", "rand_str"):
        if needle not in body:
            fail(f"{target}: oc-panel-secret.sh 缺少 {needle}")
    for rel in (HOOK_REL, FIRSTBOOT_REL):
        p = ROOT / "build" / target / rel
        if not p.is_file():
            fail(f"{target}: 缺少 {rel}")
        if "oc-panel-secret.sh" not in p.read_text(encoding="utf-8"):
            fail(f"{target}: {rel} 没有调用 oc-panel-secret.sh（密钥不会生成/同步）")


def check_jbox_clean() -> None:
    for name in JBOX_TARGETS:
        for base in ("sources", "files"):
            d = ROOT / "build" / name / base / "etc" / "openclash"
            if d.exists():
                fail(f"{name}: 不带 OpenClash 的变体不该有 {base}/etc/openclash")


def main() -> int:
    for target in TARGETS:
        check_no_plaintext(target)
        check_panel_placeholder(target)
        check_generator_wired(target)
    check_jbox_clean()
    print("NO_CREDENTIALS_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
