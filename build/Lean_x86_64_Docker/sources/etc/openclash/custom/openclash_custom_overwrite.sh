#!/bin/sh
# OpenClash 自定义覆写钩子（由 aoxi-openwrt 固件预置）
#
# OpenClash 每次生成运行配置时都会调用本脚本，传入 $1 = 运行配置路径。
# 这里做四件事：
#   1) 启动前用本地备份补齐 .mrs 规则集缓存（不需要外网）
#   2) 用 oc-mrs-slim 把配置瘦身成"只用 guize .mrs 规则"的严格模式
#   3) 幂等重打 LuCI 的 MRS 延迟面板补丁（OpenClash 升级后会被覆盖，这里自动补回）
#   4) 把被选路模型接管的策略组重新对齐成 select（换配置后自动恢复）
#
# OC_MRS_STRICT=1 严格模式：rules 里只保留 13 条 RULE-SET + MATCH 兜底
# OC_MRS_STRICT=0 关闭严格模式：保留 DOMAIN-KEYWORD / PROCESS-NAME / GEOIP 等内联规则

LOG_FILE="/tmp/openclash.log"
CONFIG_FILE="$1"

# OPENCLAW_MRS_SLIM_BEGIN
OC_MRS_STRICT="${OC_MRS_STRICT:-1}"
export OC_MRS_STRICT
if [ -f "/etc/openclash/custom/oc-mrs-slim.sh" ]; then
   if [ -x "/etc/openclash/custom/oc-mrs-restore.sh" ]; then
      /etc/openclash/custom/oc-mrs-restore.sh >> "$LOG_FILE" 2>&1
   fi
   /etc/openclash/custom/oc-mrs-slim.sh "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
   SRC_CONFIG="$(uci -q get openclash.config.config_path)"
   if [ -n "$SRC_CONFIG" ] && [ -f "$SRC_CONFIG" ] && [ "$SRC_CONFIG" != "$CONFIG_FILE" ]; then
      /etc/openclash/custom/oc-mrs-slim.sh "$SRC_CONFIG" >> "$LOG_FILE" 2>&1
   fi
fi

# 被选路模型接管的策略组对齐成 select（换配置后自动恢复；只改这份运行配置，不需要 API）
if [ -f "/etc/openclash/custom/oc-smart.rb" ]; then
   ruby /etc/openclash/custom/oc-smart.rb convert "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
fi

# LuCI 延迟面板入口：幂等重打补丁（OpenClash 升级后 Lua 文件会被覆盖）
if [ -x "/etc/openclash/custom/oc-luci-panel.rb" ]; then
   ruby /etc/openclash/custom/oc-luci-panel.rb install >> "$LOG_FILE" 2>&1
fi
# OPENCLAW_MRS_SLIM_END

exit 0
