#!/usr/bin/env python3
"""固件镜像里绝不能出现节点配置 —— 结构性保证 + 编译期断言。

要求（用户明确）：**不要把节点写入固件**。
固件仓库和 Releases 都是公开的，一旦镜像里带了节点，等于把机场订阅（节点地址、
密码、uuid）公开给所有人。所以这里不只是"记得别设密钥"，而是：

    1. 工作流里不存在任何把 Clash 配置写进镜像的步骤（连密钥入口都删掉了）；
    2. 任何一个变体的交付目录里都没有 Clash 配置文件；
    3. 交付文件里没有节点协议链接、没有顶层 proxies / proxy-groups / proxy-providers；
    4. custom.sh 不会去下载或拷贝配置文件。

刷完机要怎么用：用首启的 oc-mrs-import.sh（U 盘 / 局域网 / oc-config-url），
或者直接在 LuCI 里上传配置文件 —— 这两条都发生在设备上，不经过仓库。
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/openwrt.yml"
VARIANTS = ("Lean_x86_64", "Lean_x86_64_Docker", "Lean_x86_64_JBox", "Lean_x86_64_JBox_Docker")

# 节点协议链接（出现即说明有节点信息）
NODE_SCHEMES = (
    "vless://", "vmess://", "trojan://", "ss://", "ssr://",
    "hysteria://", "hysteria2://", "hy2://", "tuic://", "anytls://", "snell://",
)
# Clash 配置特有的顶层键
CONFIG_KEYS = re.compile(r"^(proxies|proxy-groups|proxy-providers|rule-providers)\s*:", re.M)
# 规则集文件里允许出现 rule-providers（我们自己的 .mrs 缓存），但不允许 proxies 系列
STRICT_KEYS = re.compile(r"^(proxies|proxy-groups|proxy-providers)\s*:", re.M)
# 统计文档里的节点链接：必须用"长串优先"的正则交替，否则 `ss://` 会被算进 `vless://` 里
SCHEME_RE = re.compile("|".join(re.escape(x) for x in
                                sorted(NODE_SCHEMES, key=len, reverse=True)))


def fail(message: str) -> None:
    raise AssertionError(message)


def check_workflow() -> None:
    if not WORKFLOW.is_file():
        fail("找不到工作流文件")
    text = WORKFLOW.read_text(encoding="utf-8")
    for bad in ("OPENCLASH_CONFIG", "OC_CONFIG_B64"):
        if bad in text:
            fail(f"工作流里仍存在配置注入入口 {bad}（节点会被写进公开镜像）")
    # 不允许任何步骤把 yaml/配置写进 files/ 或 sources/
    for m in re.finditer(r"^.*(files|sources)/etc/openclash/config.*$", text, re.M):
        line = m.group(0).strip()
        if "mkdir" in line or "cp " in line or ">" in line:
            fail(f"工作流里仍有往镜像写配置的动作: {line[:120]}")


def check_variant(name: str) -> None:
    base = ROOT / "build" / name
    if not base.is_dir():
        return
    for area in ("sources", "files"):
        root = base / area
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(base)

            # (1) 配置目录里不许有文件
            parts = path.parts
            if "openclash" in parts and "config" in parts:
                idx = parts.index("openclash")
                if len(parts) > idx + 2 and parts[idx + 1] == "config":
                    fail(f"{name}: 交付目录里出现了节点配置 {rel}")

            # (2) 不许有 yaml 配置
            if path.suffix.lower() in (".yaml", ".yml"):
                fail(f"{name}: 交付目录里出现了 YAML（疑似节点配置）{rel}")

            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue

            is_doc = path.suffix.lower() in (".md", ".txt")
            low = text.lower()

            # (3) 节点链接 / 配置键
            if is_doc:
                # 文档里会拿 `vless://`、`proxies:` 当例子讲，不能按字面判。
                # 但真把配置粘进文档就会露出成片的节点链接和 server/uuid/password，
                # 所以这里用"成片出现"作为判据。
                n_scheme = len(SCHEME_RE.findall(low))
                if n_scheme >= 4 or STRICT_KEYS.search(text):
                    fail(f"{name}: {rel} 里出现 {n_scheme} 处节点链接或配置键，疑似粘贴了真实配置")
                n_secret = len(re.findall(r"^\s*(server|uuid|password|cipher)\s*:\s*\S+", text, re.M))
                if n_secret >= 2:
                    fail(f"{name}: {rel} 里出现 {n_secret} 行 server/uuid/password 赋值，疑似粘贴了真实配置")
            else:
                for scheme in NODE_SCHEMES:
                    if scheme in low:
                        fail(f"{name}: {rel} 里出现了节点链接 {scheme}")
                for m in STRICT_KEYS.finditer(text):
                    fail(f"{name}: {rel} 里出现了 Clash 配置键 {m.group(0).strip()}")
                if path.suffix != ".mrs" and CONFIG_KEYS.search(text):
                    fail(f"{name}: {rel} 里出现了 Clash 配置键")

    custom = base / "custom.sh"
    if custom.is_file():
        text = custom.read_text(encoding="utf-8")
        for bad in ("zhu5in1", "OPENCLASH_CONFIG", "oc-config-url"):
            if bad in text:
                fail(f"{name}: custom.sh 里出现了 {bad}（可能在往镜像里塞配置）")


def main() -> int:
    check_workflow()
    for name in VARIANTS:
        check_variant(name)
    print("NO_NODE_CONFIG_OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
