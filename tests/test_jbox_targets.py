#!/usr/bin/env python3
"""Contract tests for the J-Box firmware targets."""

from pathlib import Path
import re
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/openwrt.yml"
TARGETS = {
    "Lean_x86_64_JBox": False,
    "Lean_x86_64_JBox_Docker": True,
}


def fail(message: str) -> None:
    raise AssertionError(message)


def check_target(name: str, docker: bool) -> None:
    target = ROOT / "build" / name
    custom = target / "custom.sh"
    settings = target / "settings.ini"
    if not custom.is_file() or not settings.is_file():
        fail(f"{name}: 缺少 custom.sh 或 settings.ini")

    text = custom.read_text(encoding="utf-8")
    if 'AOXI_PACKAGE_COMMIT="aa16dabe81cb46f57572baf689bf69782ce53dd7"' not in text:
        fail(f"{name}: aoxi-package 未固定到已审查提交")
    if "example.com/path/to" in text:
        fail(f"{name}: 仍包含无效的占位 IPK 下载地址")
    if "build/scripts/jbox/install.sh" not in text:
        fail(f"{name}: 未接入 J-Box 编译时安装脚本")
    if "CONFIG_PACKAGE_luci-app-openclash=y" in text:
        fail(f"{name}: 仍会安装 luci-app-openclash")
    if not re.search(r"# CONFIG_PACKAGE_luci-app-openclash is not set", text):
        fail(f"{name}: 未显式关闭 luci-app-openclash")
    if not re.search(r"禁止包含 OpenClash|OPENCLASH_FORBIDDEN", text):
        fail(f"{name}: 缺少 OpenClash 最终配置阻断检查")

    forbidden_paths = [p for p in target.rglob("*") if "openclash" in p.as_posix().lower()]
    if forbidden_paths:
        fail(f"{name}: 目录中残留 OpenClash 文件: {forbidden_paths[0]}")

    for path in target.rglob("*"):
        if path.is_file() and path != custom:
            try:
                content = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if "openclash" in content.lower():
                fail(f"{name}: 非构建防护文件中残留 OpenClash 内容: {path}")

    enabled = "CONFIG_PACKAGE_luci-app-dockerman=y" in text
    disabled = "# CONFIG_PACKAGE_luci-app-dockerman is not set" in text
    if docker and not enabled:
        fail(f"{name}: Docker 版未启用 luci-app-dockerman")
    if not docker and not disabled:
        fail(f"{name}: 非 Docker 版未显式关闭 luci-app-dockerman")

    expected_rootfs = "3000" if docker else "1024"
    if f"CONFIG_TARGET_ROOTFS_PARTSIZE={expected_rootfs}" not in text:
        fail(f"{name}: rootfs 分区大小不是 {expected_rootfs} MiB")

    # 旁路由 IPv6:默认开 LAN 侧 RA/DHCPv6,上游 /64 给一套默认值并交给开机脚本校正;
    # 客户端 DNS 必须只发本机(odhcpd 默认),不许出现发上游/公共 DNS 的 dhcp.lan.dns。
    for needle in (
        "uci set dhcp.lan.ra='server'",
        "uci set dhcp.lan.dhcpv6='server'",
        "uci set dhcp.lan.ra_management='2'",
        "uci set dhcp.lan.ra_preference='high'",
        "uci set dhcp.lan.ra_dns='1'",
        "uci set dhcp.lan.ndp='disabled'",
        "uci set network.lan.delegate='0'",
        "uci set network.lan6.proto='static'",
        "uci set network.lan6.jbox_auto='1'",
        "uci set dhcp.lan.ra_default='1'",
    ):
        if needle not in text:
            fail(f"{name}: 缺少 IPv6 默认配置: {needle}")
    for forbidden in (
        "uci del network.lan.ip6assign",
        "uci del dhcp.lan.ra",
        "uci del dhcp.lan.dhcpv6",
        "uci del dhcp.lan.ra_management",
        "uci set dhcp.lan.dns=",
    ):
        if forbidden in text:
            fail(f"{name}: IPv6 默认配置不该出现: {forbidden}")

    settings_text = settings.read_text(encoding="utf-8")
    if 'INHERIT_FILES="Lean_x86_64"' not in settings_text:
        fail(f"{name}: 未声明继承 Lean_x86_64 的预置文件")
    expected = f'FIRMWARE_MESSAGE="Lede_x86_64_JBox{"_Docker" if docker else ""}"'
    if expected not in settings_text:
        fail(f"{name}: FIRMWARE_MESSAGE 不正确")


def main() -> int:
    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    yaml.safe_load(workflow_text)
    for name in TARGETS:
        if f"github.event.inputs.{name}" not in workflow_text:
            fail(f"工作流未处理手动目标 {name}")
        if f'"{name}"' not in workflow_text:
            fail(f"工作流矩阵未包含 {name}")

    defconfig_pos = workflow_text.find("make defconfig")
    final_guard_pos = workflow_text.find("defconfig 后检测到 OpenClash")
    if defconfig_pos < 0 or final_guard_pos <= defconfig_pos:
        fail("工作流缺少 make defconfig 后的 OpenClash 阻断检查")

    for name, docker in TARGETS.items():
        check_target(name, docker)

    installer = ROOT / "build/scripts/jbox/install.sh"
    if not installer.is_file():
        fail("缺少 J-Box 编译时安装脚本")
    installer_text = installer.read_text(encoding="utf-8")
    for needle in (
        'REPO="aoxijy/J-box"',
        # 每次编译自动解析并拉取最新 release,不再钉死版本号与哈希
        "releases/latest",
        "j-box-${LATEST_TAG}-linux-${ASSET_ARCH}.tar.gz",
        "j-box-linux-${ASSET_ARCH}.tar.gz",
        "files/opt/j-box",
        "jbox-panel",
        "validate_archive.py",
    ):
        if needle not in installer_text:
            fail(f"J-Box 安装脚本缺少关键行为: {needle}")
    for forbidden in ("liandu2024/Open-Box", "open-box-", "files/opt/open-box"):
        if forbidden in installer_text:
            fail(f"J-Box 安装脚本仍残留旧命名: {forbidden}")

    # 旁路由 IPv6 自配置:脚本本体 + 集成进固件 + rc.local 挂钩
    helper = ROOT / "build/scripts/jbox/ipv6-lan.sh"
    if not helper.is_file():
        fail("缺少旁路由 IPv6 自配置脚本 build/scripts/jbox/ipv6-lan.sh")
    helper_text = helper.read_text(encoding="utf-8")
    for needle in (
        "ff02::1",
        "jbox_auto",
        "set_opt dhcp.lan ra server",
        "set_opt dhcp.lan dhcpv6 server",
        "set_opt dhcp.lan ndp disabled",
        "delete dhcp.lan.dns",
        "odhcpd",
        "lan6",
        "dadfailed",
        "上游没有可用的公网 /64",
    ):
        if needle not in helper_text:
            fail(f"IPv6 自配置脚本缺少关键行为: {needle}")
    for needle in (
        'cp "$SCRIPT_DIR/ipv6-lan.sh"',
        "/usr/libexec/jbox-ipv6-lan.sh",
        "grep -q 'jbox-ipv6-lan'",
    ):
        if needle not in installer_text:
            fail(f"J-Box 安装脚本未接入 IPv6 自配置: {needle}")

    update = (ROOT / ".github/workflows/update-geoip.yml").read_text(encoding="utf-8")
    for name in TARGETS:
        if f"build/{name}/" in update:
            fail(f"OpenClash 更新脚本不应触碰 {name}")

    print("JBOX_TARGET_CONTRACT_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
