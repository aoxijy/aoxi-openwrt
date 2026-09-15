#!/bin/sh
# oc-mrs-fetch.sh —— 预下载 / 手动刷新 guize 的 13 个 .mrs 规则集
#
# 目的：mihomo 的 type:http rule-provider 会优先读取本地缓存文件，
#       预先把 .mrs 放到 /etc/openclash/rule_provider/，即使 GitHub 暂时不可达也能正常启动。
#       平时 mihomo 会按 interval（86400 秒）自己更新，无需手动执行。

DIR=/etc/openclash/rule_provider
BASE=https://github.com/aoxijy/guize/releases/latest/download

mkdir -p "$DIR"

for n in ai-platform-domain ai-platform-ipcidr \
         social-chat-domain social-chat-ipcidr \
         developer-platform-domain developer-platform-ipcidr \
         foreign-media-domain foreign-media-ipcidr \
         microsoft-apple-domain microsoft-apple-ipcidr \
         direct-domain direct-ipcidr reject-domain; do
  if curl -fsSL --retry 3 --connect-timeout 15 -o "$DIR/$n.mrs.new" "$BASE/$n.mrs"; then
    mv "$DIR/$n.mrs.new" "$DIR/$n.mrs"
    printf 'ok   %-30s %8s bytes\n' "$n.mrs" "$(wc -c <"$DIR/$n.mrs" | tr -d ' ')"
  else
    rm -f "$DIR/$n.mrs.new"
    printf 'FAIL %s\n' "$n.mrs"
  fi
done
