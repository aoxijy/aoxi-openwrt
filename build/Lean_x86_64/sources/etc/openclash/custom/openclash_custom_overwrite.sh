#!/bin/sh
# OpenClash 自定义覆写钩子（由 aoxi-openwrt 固件预置）
#
# OpenClash 每次生成运行配置时都会调用本脚本，传入 $1 = 运行配置路径。
# 这里做五件事：
#   1) 启动前用本地备份补齐 .mrs 规则集缓存（不需要外网）
#   2) 用 oc-mrs-slim 把配置瘦身成"只用 guize .mrs 规则"的严格模式
#   3) 幂等重打 LuCI 的 MRS 延迟面板补丁（OpenClash 升级后会被覆盖，这里自动补回）
#   4) 把被选路模型接管的策略组重新对齐成 select（换配置后自动恢复）
#   5) 密钥自愈（生成缺失的随机密钥、补空的 secret、同步到 MRS 面板）
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

# 固定策略组名 + 订阅节点动态成员：先同步运行配置和源配置，再交给 oc-smart 转 select。
# 成员脚本失败时必须中止，避免继续使用不一致配置。
if [ -f "/etc/openclash/custom/oc-smart-members.rb" ]; then
   MEMBER_PATHS="$CONFIG_FILE"
   SRC_CONFIG="$(uci -q get openclash.config.config_path)"
   if [ -n "$SRC_CONFIG" ] && [ -f "$SRC_CONFIG" ] && [ "$SRC_CONFIG" != "$CONFIG_FILE" ]; then
      MEMBER_PATHS="$MEMBER_PATHS $SRC_CONFIG"
   fi
   # 先同时预检所有目标；任一 YAML 损坏或结构异常时，一个文件也不写，避免源/运行配置半更新。
   ruby /etc/openclash/custom/oc-smart-members.rb --check $MEMBER_PATHS >> "$LOG_FILE" 2>&1
   if [ $? -ne 0 ]; then
      echo "[oc-smart-members] preflight failed; abort openclash overwrite hook" >> "$LOG_FILE"
      exit 1
   fi
   ruby /etc/openclash/custom/oc-smart-members.rb $MEMBER_PATHS >> "$LOG_FILE" 2>&1
   if [ $? -ne 0 ]; then
      echo "[oc-smart-members] sync failed; abort openclash overwrite hook" >> "$LOG_FILE"
      exit 1
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

# 密钥自愈 + 面板同步：
#   · 镜像不带固定凭据，dashboard_password 为空时现场生成设备专属随机值
#   · 若这次生成的运行配置里 secret 还是空的，顺手补上，避免出现"无密钥的 API"
#   · 把当前密钥写进 MRS 面板，用户改过密码后面板也跟得上
if [ -x "/etc/openclash/custom/oc-panel-secret.sh" ]; then
   /etc/openclash/custom/oc-panel-secret.sh >> "$LOG_FILE" 2>&1
   OC_SEC="$(uci -q get openclash.config.dashboard_password)"
   if [ -n "$OC_SEC" ] && [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
      if grep -qE '^secret:[[:space:]]*$' "$CONFIG_FILE"; then
         awk -v s="$OC_SEC" '/^secret:[[:space:]]*$/ && !d { print "secret: " s; d=1; next } { print }' \
            "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      elif ! grep -qE '^secret:' "$CONFIG_FILE"; then
         printf 'secret: %s\n' "$OC_SEC" >> "$CONFIG_FILE"
      fi
   fi
fi
# OPENCLAW_MRS_SLIM_END

exit 0
