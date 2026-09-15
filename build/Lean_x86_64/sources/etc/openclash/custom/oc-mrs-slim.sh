#!/bin/sh
# oc-mrs-slim.sh —— 用 guize 的 .mrs 规则集替换内联 rules，给 OpenClash 配置瘦身
#
# 用法:
#   /etc/openclash/custom/oc-mrs-slim.sh                          # 处理当前 OpenClash 选中的配置
#   /etc/openclash/custom/oc-mrs-slim.sh <config.yaml>            # 处理指定配置
#   /etc/openclash/custom/oc-mrs-slim.sh <config.yaml> --strict   # rules 里只留 13 条 RULE-SET + MATCH
#   /etc/openclash/custom/oc-mrs-slim.sh <config.yaml> --dry-run  # 只预览不写回
#
# --strict 等价于环境变量 OC_MRS_STRICT=1。
# 由 /etc/openclash/custom/openclash_custom_overwrite.sh 在每次生成运行配置时自动调用。

CONFIG=""
FLAGS=""
for arg in "$@"; do
  case "$arg" in
    --*) FLAGS="$FLAGS $arg" ;;
    *) [ -z "$CONFIG" ] && CONFIG="$arg" ;;
  esac
done

if [ -z "$CONFIG" ]; then
  CONFIG="$(uci -q get openclash.config.config_path)"
fi
if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "[oc-mrs-slim] config not found: $CONFIG" >&2
  exit 1
fi

exec ruby /etc/openclash/custom/oc_mrs_slim.rb "$CONFIG" $FLAGS
