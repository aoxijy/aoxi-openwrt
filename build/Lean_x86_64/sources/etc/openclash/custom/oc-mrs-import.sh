#!/bin/sh
# oc-mrs-import.sh —— 没有外网也能给路由器装上 Clash 配置
#
# 固件默认不预置节点配置（镜像会发到公开的 Releases，避免节点信息泄露）。
# 如果你想让刷机后自动有配置，二选一：
#   A. U 盘：把配置文件命名为 zhu5in1.yaml，放到 U 盘根目录（或 /openclash/ 子目录），
#      插上路由器，开机（或手动跑一次本脚本）就会自动导入
#   B. 局域网 HTTP：把局域网里能下载到配置的地址写进
#      /etc/openclash/custom/oc-config-url（一行 http(s)://...），
#      开机时网络已通就会自动下载导入
#
# 用法:
#   /etc/openclash/custom/oc-mrs-import.sh            # 有配置就跳过，没有才导入
#   /etc/openclash/custom/oc-mrs-import.sh --force    # 覆盖已有配置

DEST=/etc/openclash/config/zhu5in1.yaml
URL_FILE=/etc/openclash/custom/oc-config-url
FORCE=""
[ "$1" = "--force" ] && FORCE=1

if [ -s "$DEST" ] && [ -z "$FORCE" ]; then
    echo "[oc-mrs-import] 已有配置 $DEST，跳过（要覆盖加 --force）"
    exit 0
fi

FOUND=""

# A. U 盘
for f in /mnt/*/zhu5in1.yaml /mnt/*/openclash/zhu5in1.yaml /mnt/*/*/zhu5in1.yaml \
         /mnt/*/openclash.yaml /mnt/*/config.yaml; do
    if [ -s "$f" ]; then
        FOUND="$f"
        break
    fi
done

# B. 局域网 URL
if [ -z "$FOUND" ] && [ -s "$URL_FILE" ]; then
    URL="$(head -n1 "$URL_FILE" | tr -d ' \r\n')"
    case "$URL" in
        http://*|https://*)
            TMP=/tmp/oc-config-import.yaml
            if curl -fsSL --connect-timeout 8 --max-time 30 -o "$TMP" "$URL" && [ -s "$TMP" ]; then
                FOUND="$TMP"
            else
                echo "[oc-mrs-import] 从 $URL 下载失败（网络没通？稍后可重跑本脚本）"
            fi
            ;;
    esac
fi

if [ -z "$FOUND" ]; then
    echo "[oc-mrs-import] 没找到可导入的配置（U 盘/局域网都没有），跳过"
    exit 0
fi

# 简单校验，别把坏文件装进去
if ! grep -q "^proxies:" "$FOUND" || ! grep -q "^proxy-groups:" "$FOUND"; then
    echo "[oc-mrs-import] $FOUND 看起来不是 Clash 配置，已忽略"
    [ "$FOUND" = "/tmp/oc-config-import.yaml" ] && rm -f "$FOUND"
    exit 1
fi

mkdir -p /etc/openclash/config
cp -f "$FOUND" "$DEST"
chmod 600 "$DEST"
echo "[oc-mrs-import] 已从 $FOUND 导入配置到 $DEST（$(wc -c < "$DEST") bytes）"

# 顺手按严格模式瘦身（幂等）
[ -x /etc/openclash/custom/oc-mrs-slim.sh ] && /etc/openclash/custom/oc-mrs-slim.sh "$DEST" --strict

exit 0
