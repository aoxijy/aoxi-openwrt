#!/bin/sh
# oc-mrs-restore.sh —— 从本地备份恢复 .mrs 规则集缓存（完全不需要网络）
#
# 为什么需要它：
#   配置里 13 个 rule-providers 是 type: http，mihomo 启动时**优先读 path 指向的本地文件**，
#   只有文件不存在时才必须联网下载。所以只要 /etc/openclash/rule_provider/*.mrs 还在，
#   断网也能正常启动、正常分流（下载失败只在日志里报一行 error，不影响运行）。
#   这个脚本负责在文件被误删/新机器首次部署时，从本地备份补齐。
#
# 用法:
#   /etc/openclash/custom/oc-mrs-restore.sh            # 缺什么补什么
#   /etc/openclash/custom/oc-mrs-restore.sh --check    # 只检查不复制
#   /etc/openclash/custom/oc-mrs-restore.sh --backup   # 反向：把当前缓存备份一份
#   /etc/openclash/custom/oc-mrs-restore.sh --install-cron   # 装一个每 10 分钟的兜底自愈
#   /etc/openclash/custom/oc-mrs-restore.sh --remove-cron    # 卸掉兜底自愈

DIR=/etc/openclash/rule_provider
BAK=/etc/openclash/custom/mrs-backup
CRON=/etc/crontabs/root
CRON_LINE='*/10 * * * * /etc/openclash/custom/oc-mrs-restore.sh >/dev/null 2>&1 #oc-mrs-selfheal'

mkdir -p "$BAK" "$DIR"

case "$1" in
  --install-cron)
    if grep -q "oc-mrs-selfheal" "$CRON" 2>/dev/null; then
      echo "[oc-mrs-restore] 兜底 cron 已存在"
    else
      echo "$CRON_LINE" >> "$CRON"
      crontab "$CRON" 2>/dev/null
      /etc/init.d/cron restart >/dev/null 2>&1
      echo "[oc-mrs-restore] 已安装兜底 cron（每 10 分钟检查一次缓存，缺了就从本地备份补）"
    fi
    exit 0
    ;;
  --remove-cron)
    sed -i '/oc-mrs-selfheal/d' "$CRON" 2>/dev/null
    crontab "$CRON" 2>/dev/null
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "[oc-mrs-restore] 已移除兜底 cron"
    exit 0
    ;;
esac

if [ "$1" = "--backup" ]; then
  n=0
  for f in "$DIR"/*.mrs; do
    [ -f "$f" ] || continue
    cp -f "$f" "$BAK/$(basename "$f")" && n=$((n + 1))
  done
  echo "[oc-mrs-restore] 已备份 $n 个 .mrs 到 $BAK"
  exit 0
fi

total=0
missing=0
restored=0
for f in "$BAK"/*.mrs; do
  [ -f "$f" ] || continue
  total=$((total + 1))
  name=$(basename "$f")
  if [ -s "$DIR/$name" ]; then
    continue
  fi
  missing=$((missing + 1))
  if [ "$1" = "--check" ]; then
    echo "[oc-mrs-restore] 缺失: $name"
  else
    cp -f "$f" "$DIR/$name" && restored=$((restored + 1)) && echo "[oc-mrs-restore] 已恢复 $name"
  fi
done

if [ "$total" = "0" ]; then
  echo "[oc-mrs-restore] 备份目录为空: $BAK" >&2
  exit 1
fi

if [ "$missing" = "0" ]; then
  echo "[oc-mrs-restore] $total 个规则集缓存都在，无需恢复"
elif [ "$1" = "--check" ]; then
  echo "[oc-mrs-restore] 共 $missing/$total 个缺失（加 --backup / 联网跑 oc-mrs-fetch.sh 可补齐）"
else
  echo "[oc-mrs-restore] 已恢复 $restored/$missing 个缺失文件"
fi
