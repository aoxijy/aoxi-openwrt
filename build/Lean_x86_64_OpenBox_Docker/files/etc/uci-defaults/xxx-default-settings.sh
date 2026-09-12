#!/bin/sh

# 将默认 shell 改为 bash
if [ -f /bin/bash ]; then
  sed -i '/^root:/s#/bin/ash#/bin/bash#' /etc/passwd
fi

# 设置默认主机名
uci set system.@system[0].hostname='GanQuanRu'

# 设置默认主题
uci set luci.main.mediaurlbase='/luci-static/design'
uci commit luci

# 添加系统信息
if ! grep -q "shell-motd" /etc/profile; then
cat >> /etc/profile <<'EOF'

# 添加系统信息
[ -n "$FAILSAFE" -a -x /bin/bash ] || {
	for FILE in /etc/shell-motd.d/*.sh; do
		[ -f "$FILE" ] && env -i bash "$FILE"
	done
	unset FILE
}

# 设置 nano 为默认编辑器
export EDITOR="/usr/bin/nano"

EOF
fi

exit 0
