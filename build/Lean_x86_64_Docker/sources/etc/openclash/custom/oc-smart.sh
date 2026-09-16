#!/bin/sh
# oc-smart.sh —— 本地「模型优选节点」入口
#
# 做什么：
#   每轮给"被接管的组"里的每个节点测速，每节点保留最近 N 条记录（默认 10），
#   按「延迟 + 抖动 + 超时」算稳定性得分，然后在**每个组自己的成员里**挑最优（绝不跨组），
#   当前节点没有明显更差就保持不动（防抖），你在面板上手动改过的组会让位一段时间。
#
# 用法:
#   oc-smart.sh cycle           测一轮 + 重新选一次（cron 跑这个）
#   oc-smart.sh select          只用已有记录重选一次（不测速，很快）
#   oc-smart.sh select --force  同上，但忽略"手动让位"，强制按模型结果重选
#   oc-smart.sh status          看每个组的当前节点 / 得分 / 候选前三
#   oc-smart.sh type            看被接管的组现在是什么类型
#   oc-smart.sh convert         把这些组改成 select（模型才能控制它们的选择）
#   oc-smart.sh revert          改回 url-test（交回 mihomo 自己测速）
#   oc-smart.sh reset           清空测试记录
#   oc-smart.sh watchdog         兜底：模型太久没更新就把分组交回内核(url-test)
#   oc-smart.sh --install-cron  装定时任务（间隔看 oc-smart.conf 的 CYCLE_MIN）
#   oc-smart.sh --remove-cron   卸掉定时任务
#
# 配置: /etc/openclash/custom/oc-smart.conf
# 记录: /etc/openclash/smart/history.json（每节点最近 N 条）
# 日志: /tmp/openclash_smart.log

CONF=/etc/openclash/custom/oc-smart.conf
CRON=/etc/crontabs/root

case "$1" in
  watchdog)
    # 模型挂了的兜底：状态文件太久没更新 → 把被接管的组交回内核(url-test)自管，
    # 之后模型恢复时，下一轮 cycle 的 ensure_groups_selectable 会自动再转回 select
    STALE=$(grep '^STALE_MINUTES=' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [ -z "$STALE" ] && STALE=30
    if [ ! -f /etc/openclash/smart/status.txt ]; then
      echo "[watchdog] 还没有状态文件（模型没跑过），跳过"
      exit 0
    fi
    if [ -n "$(find /etc/openclash/smart/status.txt -mmin +$STALE 2>/dev/null)" ]; then
      echo "[watchdog] 状态文件超过 ${STALE} 分钟没更新 → 把分组交回内核(url-test)自管"
      exec ruby /etc/openclash/custom/oc-smart.rb revert
    fi
    echo "[watchdog] 模型正常（状态文件新鲜）"
    exit 0
    ;;
  --install-cron)
    if grep -q "oc-smart-selfrun" "$CRON" 2>/dev/null; then
      echo "[oc-smart] 定时任务已存在"
      exit 0
    fi
    INTERVAL=$(grep '^CYCLE_MIN=' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' ')
    [ -z "$INTERVAL" ] && INTERVAL=5
    echo "*/$INTERVAL * * * * /etc/openclash/custom/oc-smart.sh cycle >/dev/null 2>&1 #oc-smart-selfrun" >> "$CRON"
    grep -q "oc-smart-watchdog" "$CRON" 2>/dev/null || echo "*/10 * * * * /etc/openclash/custom/oc-smart.sh watchdog >/dev/null 2>&1 #oc-smart-watchdog" >> "$CRON"
    crontab "$CRON" 2>/dev/null
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "[oc-smart] 已安装定时任务：每 $INTERVAL 分钟一轮 + 每 10 分钟看门狗"
    exit 0
    ;;
  --remove-cron)
    sed -i '/oc-smart-selfrun/d;/oc-smart-watchdog/d' "$CRON" 2>/dev/null
    crontab "$CRON" 2>/dev/null
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "[oc-smart] 已移除定时任务"
    exit 0
    ;;
esac

# 加锁，避免 cron 与手动执行撞车
mkdir -p /tmp/lock
if command -v flock >/dev/null 2>&1; then
  exec 9>/tmp/lock/oc-smart.lock
  flock -n 9 || { echo "[oc-smart] 已有实例在跑，本次退出"; exit 0; }
fi

exec ruby /etc/openclash/custom/oc-smart.rb "$@"
