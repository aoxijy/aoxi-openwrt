#!/bin/sh
# OpenClash 自定义覆写钩子（由 aoxi-openwrt 固件预置）
#
# OpenClash 每次生成运行配置时都会调用本脚本，传入 $1 = 运行配置路径。
# 这里做两件事：
#   1) 启动前用本地备份补齐 .mrs 规则集缓存（不需要外网）
#   2) 用 oc-mrs-slim 把配置瘦身成"只用 guize .mrs 规则"的严格模式
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
# OPENCLAW_MRS_SLIM_END

exit 0
