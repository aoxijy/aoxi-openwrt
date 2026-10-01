#!/bin/sh
# 强制 iptables/ip6tables 使用 nftables 后端 (xtables-nft-multi)
# 目的: 固件只使用 fw4 (nftables)，任何插件写入的 iptables 规则都落到
#       nftables 兼容表，不再产生旧版 ip_tables 规则，
#       消除 LuCI "系统上存在旧版 iptables 规则" 警告。
# 幂等，仅首次开机执行；无 xtables-nft-multi 时静默跳过。

NFT=/usr/sbin/xtables-nft-multi
[ -x "$NFT" ] || { echo "nft-backend: xtables-nft-multi missing; skip"; exit 0; }

# 将 iptables 命令族指向 nft 多后端二进制
for cmd in iptables iptables-save iptables-restore \
           ip6tables ip6tables-save ip6tables-restore; do
	ln -sf xtables-nft-multi "/usr/sbin/$cmd" 2>/dev/null
done

# 清理可能残留的旧版规则，保证以全新 nftables 规则启动
for t in filter nat mangle raw; do
	iptables-legacy -t "$t" -F 2>/dev/null
	iptables-legacy -t "$t" -X 2>/dev/null
	ip6tables-legacy -t "$t" -F 2>/dev/null
	ip6tables-legacy -t "$t" -X 2>/dev/null
done

exit 0
