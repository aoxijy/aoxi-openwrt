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

    # 原来这里检查 update-geoip.yml 不碰 J-Box 目标；该工作流已随 GeoIP.dat/GeoSite.dat/
    # Country.mmdb/ASN.mmdb 一起移除（严格模式规则里已无 GEOIP/GEOSITE/IP-ASN 规则）。
    # 改成检查新的契约：带 OpenClash 的变体必须预置 mrs 规则集与配套脚本，
    # J-Box 变体（sources 不继承）不得出现 OpenClash 数据。
    if (ROOT / ".github/workflows/update-geoip.yml").exists():
        fail("update-geoip.yml 应已移除（geo 数据不再需要）")
    for name in ("Lean_x86_64", "Lean_x86_64_Docker"):
        base = ROOT / "build" / name / "sources" / "etc" / "openclash"
        guize = sorted(p for p in (base / "rule_provider").glob("*.mrs") if p.name != "oc-cn-domain.mrs")
        if len(guize) != 13:
            fail(f"{name}: 预置的 guize mrs 规则集应为 13 个，实际 {len(guize)}")
        # OpenClash 自己会给 fake-ip-filter 加 rule-set:oc-cn-domain，没网时必须靠预置文件，
        # 否则内核会因为下载不到规则集直接启动失败
        if not (base / "rule_provider" / "oc-cn-domain.mrs").is_file():
            fail(f"{name}: 缺少 oc-cn-domain.mrs（断网启动必需）")
        backup = sorted((base / "custom" / "mrs-backup").glob("*.mrs"))
        if len(backup) != 14:
            fail(f"{name}: mrs 本地备份应为 14 个，实际 {len(backup)}")
        for script in ("oc-mrs-slim.sh", "oc-mrs-restore.sh", "oc-mrs-fetch.sh",
                       "oc-patch-yamlrb.sh", "oc-mrs-import.sh", "oc_mrs_slim.rb", "openclash_custom_overwrite.sh",
                       "oc-smart.rb", "oc-smart.sh", "oc-smart.conf", "oc-luci-panel.rb"):
            if not (base / "custom" / script).is_file():
                fail(f"{name}: 缺少 OpenClash mrs 脚本 {script}")
        # MRS 延迟面板：模板 + 面板页面 + LuCI 入口 + 选路模型接线
        for tpl in ("mrs_panel.htm", "mrs_panel_setting.htm"):
            if not (base / "custom" / "luci" / tpl).is_file():
                fail(f"{name}: 缺少 LuCI 模板 luci/{tpl}")
        if not (ROOT / "build" / name / "sources" / "usr/share/openclash/ui/mrs-panel/index.html").is_file():
            fail(f"{name}: 缺少 MRS 延迟面板 index.html")
        uci_defaults = (ROOT / "build" / name / "sources" / "etc" / "uci-defaults" / "97-openclash-mrs").read_text(encoding="utf-8")
        for needle in ("oc-luci-panel.rb install", "convert", "--install-cron"):
            if needle not in uci_defaults:
                fail(f"{name}: 首启脚本缺少步骤 {needle}")
        hook = (base / "custom" / "openclash_custom_overwrite.sh").read_text(encoding="utf-8")
        if "oc-luci-panel.rb install" not in hook or "convert" not in hook:
            fail(f"{name}: OpenClash 钩子未接入面板补丁/分组对齐")
        cfg_sh = (ROOT / "build" / name / "custom.sh").read_text(encoding="utf-8")
        if "CONFIG_PACKAGE_ruby-json=y" not in cfg_sh:
            fail(f"{name}: 未启用 ruby-json 依赖")
        if not (ROOT / "build" / name / "sources" / "etc" / "uci-defaults" / "97-openclash-mrs").is_file():
            fail(f"{name}: 缺少首次启动脚本 97-openclash-mrs")
        cfg = (ROOT / "build" / name / "sources" / "etc" / "config" / "openclash").read_text(encoding="utf-8")
        if "config_path '/etc/openclash/config/zhu5in1.yaml'" not in cfg:
            fail(f"{name}: uci 未指定 config_path")
        # 规则已全部走 .mrs，不需要 GeoIP.dat；勾上反而会去找已经不预置的 geo 数据
        if "option enable_geoip_dat '0'" not in cfg:
            fail(f"{name}: 应默认关闭「启用 GeoIP Dat 版数据库」")
        # Fake-IP-Filter 必须开启，否则自建服务域名会被 fake-ip 接管
        if "option custom_fakeip_filter '1'" not in cfg:
            fail(f"{name}: 应默认开启 Fake-IP-Filter")
        if "option custom_fakeip_filter_mode 'blacklist'" not in cfg:
            fail(f"{name}: Fake-IP-Filter 模式应为 blacklist")
        fake_list = (base / "custom" / "openclash_custom_fake_filter.list").read_text(encoding="utf-8")
        for dom in ("+.gqru.com", "*.gqru.com", "+.jgyu.com", "*.jgyu.com"):
            if f"\n{dom}\n" not in f"\n{fake_list}":
                fail(f"{name}: fake-ip-filter 列表缺少 {dom}")
        for geo in ("GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb"):
            if (base / geo).exists():
                fail(f"{name}: 不该再预置 {geo}")
        # 我们自己不预置了，但 luci-app-openclash 包里还自带 GeoSite.dat + Country.mmdb，
        # 必须在 custom.sh 里从包源码删掉，否则镜像里照样有 10.6MB 用不到的 geo 数据
        csh = (ROOT / "build" / name / "custom.sh").read_text(encoding="utf-8")
        for geo in ("GeoSite.dat", "Country.mmdb"):
            if f"luci-app-openclash/root/etc/openclash/{geo}" not in csh:
                fail(f"{name}: custom.sh 未从 openclash 包里去掉 {geo}")
    for name in TARGETS:
        if (ROOT / "build" / name / "sources" / "etc" / "openclash").exists():
            fail(f"J-Box 目标 {name} 不应包含 OpenClash 数据")

    # 选路模型的快速守护必须"候选实测验证后再切"，并且通用测速地址用 HTTPS
    for name in ("Lean_x86_64", "Lean_x86_64_Docker"):
        base = ROOT / "build" / name / "sources" / "etc" / "openclash" / "custom"
        rb = (base / "oc-smart.rb").read_text(encoding="utf-8")
        guard = rb[rb.index("def run_guard"):rb.index("# ---------- status ----------")]
        if "GUARD_VERIFY_MAX" not in rb or "GUARD_VERIFY_MAX" not in (base / "oc-smart.conf").read_text(encoding="utf-8"):
            fail(f"{name}: guard 缺少 GUARD_VERIFY_MAX（候选实测上限）")
        if "test_delay(x, turl, texp, tmo)" not in guard:
            fail(f"{name}: guard 切换前没有实测候选节点（会切到另一个死节点）")
        if "连测两次不通" not in guard:
            fail(f"{name}: guard 没有「单次抖动先复测」的逻辑")
        conf = (base / "oc-smart.conf").read_text(encoding="utf-8")
        if "TEST_URL=https://www.gstatic.com/generate_204" not in conf:
            fail(f"{name}: 通用测速地址应为 HTTPS（HTTP 测不出 TLS 到 Google 被墙的节点）")

    print("JBOX_TARGET_CONTRACT_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
