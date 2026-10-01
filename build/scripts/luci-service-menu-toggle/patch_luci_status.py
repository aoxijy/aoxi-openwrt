#!/usr/bin/env python3
"""Patch LuCI's status overview with the Services menu toggle row."""

from pathlib import Path
import sys

ROOT = Path.cwd()
CANDIDATES = (
    ROOT / "feeds/luci/modules/luci-mod-status/ucode/template/admin_status/index.ut",
    ROOT / "package/feeds/luci/luci-mod-status/ucode/template/admin_status/index.ut",
)
MARKER = "admin/status/service-menu-toggle"
ANCHOR = """<script>
\tL.require('ui').then(function(ui) {
\t\tui.instantiateView('status/index');
\t});
</script>

{% include('footer') %}"""
REPLACEMENT = """<script>
\tL.require('ui').then(function(ui) {
\t\tui.instantiateView('status/index');
\t});
</script>

{%
\tlet service_menu_visible = (uci.get('luci_service_menu', 'main', 'visible') != '0');
%}
<div class=\"cbi-section\">
\t<div class=\"cbi-title\">
\t\t<h3 style=\"display:flex;justify-content:space-between;align-items:center\">
\t\t\t<span>服务</span>
\t\t\t<form method=\"post\" action=\"{{ dispatcher.build_url('admin/status/service-menu-toggle') }}\" style=\"margin:0\">
\t\t\t\t<input type=\"hidden\" name=\"token\" value=\"{{ entityencode(ctx.authtoken, true) }}\" />
\t\t\t\t<input type=\"hidden\" name=\"visible\" value=\"{{ service_menu_visible ? '0' : '1' }}\" />
\t\t\t\t<button type=\"submit\"
\t\t\t\t\tclass=\"{{ service_menu_visible ? 'label' : 'label notice' }}\"
\t\t\t\t\tdata-style=\"{{ service_menu_visible ? 'inactive' : 'active' }}\"
\t\t\t\t\tstyle=\"display:flex;align-items:center;justify-content:center;min-width:4em;border:0;cursor:pointer\">
\t\t\t\t\t{{ service_menu_visible ? '隐藏' : '显示' }}
\t\t\t\t</button>
\t\t\t</form>
\t\t</h3>
\t</div>
</div>

{% include('footer') %}"""


def main() -> int:
    paths = []
    for candidate in CANDIDATES:
        if candidate.exists():
            resolved = candidate.resolve()
            if resolved not in paths:
                paths.append(resolved)

    if not paths:
        print("错误: 找不到 luci-mod-status 的 admin_status/index.ut", file=sys.stderr)
        return 1

    for path in paths:
        text = path.read_text(encoding="utf-8")
        if MARKER in text:
            print(f"服务菜单开关已存在: {path}")
            continue
        if ANCHOR not in text:
            print(f"错误: LuCI 概况模板结构变化，无法安全打补丁: {path}", file=sys.stderr)
            return 1
        path.write_text(text.replace(ANCHOR, REPLACEMENT, 1), encoding="utf-8")
        print(f"已添加服务菜单开关: {path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
