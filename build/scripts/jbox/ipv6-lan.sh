#!/bin/sh
# J-Box 固件:旁路由 IPv6 自配置(由 /etc/rc.local 在开机、network 起来之后后台调用一次;幂等)
#
# 场景与目标
#   本机是旁路由:IPv4 与主路由同网段,默认网关指主路由;主路由不开 RA / 不做 DHCPv6-PD,
#   所以下游客户端拿不到 IPv6。这里在不改动用户配置的前提下补齐:
#     1) 从本机所在二层网段里认一个上游公网 /64(优先取 IPv4 网关自己的全局地址,其次取
#        同 /64 邻居最多的那个 /64),给 br-lan 配静态地址 + 默认路由;
#     2) 断言 LAN 侧 RA / DHCPv6 服务与「DNS 只发本机」的选项,再由 odhcpd 向下发。
#
# 为什么 DNS 必须只发本机
#   RDNSS / DHCPv6 里发出去的 DNS 会被客户端直接使用,发上游或公共 DNS 就等于把解析交出去:
#   走代理的域名拿到的是被污染的结果,IPv6 这条路绕过了本机的分流。odhcpd 的 dns 默认是
#   「接口自己的地址」,dns_service 默认 1,所以只要不显式写 dhcp.lan.dns,客户端拿到的
#   就是本机地址;再把 ndp 保持 disabled,不把上游 RA 里的前缀 / DNS 代答下去。
#
# 边界
#   只维护 network.lan6,且该节带 jbox_auto='1'。用户自己在 LuCI / uci 配过 IPv6(任何别的
#   接口带 ip6addr / ip6prefix / ip6gw / proto dhcpv6 之类)就整体退出,一个字节都不动。
#
# 调试
#   JBOX_IPV6_DRYRUN=1 只探测并打印结论,不写任何 uci、不动网络。
set -u

TAG=jbox-ipv6
DRYRUN="${JBOX_IPV6_DRYRUN:-0}"
log() { logger -t "$TAG" "$*" 2>/dev/null || true; }
skip() { [ "$DRYRUN" = 1 ] && echo "跳过:$*"; log "$*"; exit 0; }

DEV=$(uci -q get network.lan.device || echo br-lan)
LANIP=$(uci -q get network.lan.ipaddr || echo "")
GW4=$(uci -q get network.lan.gateway || echo "")
[ -n "$DEV" ] || skip "拿不到 network.lan.device,跳过"

# ---- 尊重用户配置:除 lan6 外任何接口带 IPv6 配置就退出 ----
for section in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=.*/\1/p' | sort -u); do
	[ "$section" = "lan6" ] && continue
	for opt in ip6addr ip6prefix ip6gw; do
		[ -n "$(uci -q get "network.$section.$opt")" ] && skip "检测到用户自配 IPv6(network.$section.$opt),跳过"
	done
	case "$(uci -q get "network.$section.proto")" in
		dhcpv6|6in4|6to4|6rd|dslite) skip "检测到用户自配 IPv6(network.$section.proto),跳过" ;;
	esac
done
if [ -n "$(uci -q get network.lan6)" ] && [ "$(uci -q get network.lan6.jbox_auto || echo '')" != "1" ] && [ "$DRYRUN" != 1 ]; then
	skip "network.lan6 不是自检脚本维护的,跳过"
fi

# ---- 1. 认上游 /64 ----
# 组播 ping 让网段里所有 IPv6 主机的邻居表项就位(客户端、上游路由器的地址都会出现)
ping6 -c 2 -W 1 "ff02::1%$DEV" >/dev/null 2>&1

gw_mac=""
if [ -n "$GW4" ]; then
	gw_mac=$(ip neigh show "$GW4" 2>/dev/null | awk '/lladdr/{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}' | head -1)
	if [ -z "$gw_mac" ]; then
		ping -c 1 -W 1 "$GW4" >/dev/null 2>&1
		gw_mac=$(ip neigh show "$GW4" 2>/dev/null | awk '/lladdr/{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}' | head -1)
	fi
fi

neigh=$(ip -6 neigh show dev "$DEV" 2>/dev/null)
prefix=""
gw6=""

# 1a. 优先:IPv4 网关(主路由)自己在同一网段的全局地址
if [ -n "$gw_mac" ]; then
	for addr in $(echo "$neigh" | awk -v mac="$gw_mac" '{for(i=1;i<=NF;i++) if(tolower($i)==tolower(mac)) print $1}'); do
		case "$addr" in
			[23][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:*) prefix=$(echo "$addr" | cut -d: -f1-4); break ;;
		esac
	done
	for addr in $(echo "$neigh" | awk -v mac="$gw_mac" '{for(i=1;i<=NF;i++) if(tolower($i)==tolower(mac)) print $1}'); do
		case "$addr" in fe80:*) gw6="$addr"; break ;; esac
	done
fi

# 1b. 退一步:邻居最多的公网 /64(至少 2 个不同 MAC,避免捡到手机/热点之类的别的网络)
if [ -z "$prefix" ]; then
	prefix=$(echo "$neigh" | awk '
		{
			addr = $1; mac = ""
			for (i = 1; i <= NF; i++) if ($i == "lladdr") mac = $(i + 1)
			if (addr !~ /^[23][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:/) next
			if (mac == "") next
			split(addr, p, ":"); pref = p[1] ":" p[2] ":" p[3] ":" p[4]
			key = pref " " mac
			if (key in seen) next
			seen[key] = 1; cnt[pref]++
		}
		END { best = ""; bestn = 1; for (p in cnt) if (cnt[p] > bestn) { bestn = cnt[p]; best = p } print best }')
fi
if [ -z "$prefix" ]; then
	# 没找到上游 /64:如果 lan6 是本脚本自己建的,把它撤掉 —— 免得继续广播一个已经不存在的
	# 前缀(ra_default=1 只保证"没有公网地址时不发默认路由",PIO 还是会发)。用户自己配的 IPv6 不动。
	if [ -n "$(uci -q get network.lan6 || echo '')" ] && [ "$(uci -q get network.lan6.jbox_auto || echo '')" = "1" ]; then
		uci -q delete network.lan6
		uci commit network
		ubus call network.interface.lan6 down >/dev/null 2>&1 || true
		/etc/init.d/odhcpd reload >/dev/null 2>&1 || /etc/init.d/odhcpd restart >/dev/null 2>&1 || true
		log "上游没有可用的公网 /64,已撤掉自建的 lan6(不再广播不存在的 v6 前缀)"
	fi
	skip "网段里暂时没有可用的公网 /64(等上游/客户端拿到 IPv6 后再试),保持现状"
fi

# 网关:优先主路由的链路本地地址,取不到就用带全局地址的设备的链路本地
if [ -z "$gw6" ]; then
	gw6=$(echo "$neigh" | awk '
		{
			addr = $1; mac = ""
			for (i = 1; i <= NF; i++) if ($i == "lladdr") mac = $(i + 1)
			if (mac == "") next
			if (addr ~ /^fe80:/) { ll[mac] = addr; next }
			if (addr ~ /^[23]/) has[mac] = 1
		}
		END { for (m in has) if (m in ll) { print ll[m]; exit } }')
fi
[ -n "$gw6" ] || gw6=$(uci -q get network.lan6.ip6gw || echo "")

# 主机位:用 IPv4 末位(172.18.18.2 → ::2),和现网习惯一致
hostid=$(printf '%x' "$(echo "$LANIP" | awk -F. '{print $4}')" 2>/dev/null || echo "")
case "$hostid" in ''|0*|0|1) hostid=2 ;; esac
newaddr="$prefix::$hostid/64"
oldaddr=$(uci -q get network.lan6.ip6addr || echo "")
oldgw=$(uci -q get network.lan6.ip6gw || echo "")

if [ "${JBOX_IPV6_DRYRUN:-0}" = "1" ]; then
	printf 'dev=%s lanip=%s gw4=%s gw_mac=%s prefix=%s gw6=%s addr=%s (当前 %s / %s)\n' \
		"$DEV" "$LANIP" "$GW4" "${gw_mac:-无}" "$prefix" "${gw6:-无}" "$newaddr" "${oldaddr:-无}" "${oldgw:-无}"
	exit 0
fi

# ---- 2. LAN 侧 IPv6 服务:开 RA/DHCPv6,DNS 只发本机 ----
changed=0
set_opt() { # <section> <option> <value>
	[ "$(uci -q get "$1.$2" || echo '')" = "$3" ] || { uci set "$1.$2=$3"; changed=1; }
}
set_opt dhcp.lan ra server
set_opt dhcp.lan dhcpv6 server
set_opt dhcp.lan ra_management 2
set_opt dhcp.lan ra_preference high
set_opt dhcp.lan ra_dns 1
set_opt dhcp.lan ndp disabled
set_opt network.lan delegate 0
if [ -n "$(uci -q get dhcp.lan.dns || echo '')" ]; then
	uci -q delete dhcp.lan.dns
	changed=1
	log "已删掉 dhcp.lan.dns:IPv6 DNS 交给 odhcpd 发本机地址,避免上游污染"
fi

# ---- 3. 落实 lan6(地址或网关变了才动) ----
if [ "$newaddr" != "$oldaddr" ] || { [ -n "$gw6" ] && [ "$gw6" != "$oldgw" ]; }; then
	uci set network.lan6=interface
	uci set network.lan6.device="$DEV"
	uci set network.lan6.proto=static
	uci set network.lan6.ip6addr="$newaddr"
	[ -n "$gw6" ] && uci set network.lan6.ip6gw="$gw6"
	uci set network.lan6.jbox_auto=1
	changed=1
	log "LAN IPv6 $oldaddr → $newaddr (gw ${gw6:-$oldgw})"
fi

[ "$changed" = 1 ] || exit 0
uci commit network
uci commit dhcp
ifup lan6 >/dev/null 2>&1 || ubus call network.interface.lan6 up >/dev/null 2>&1

# DAD 冲突(网段里已经有同一个地址):换一个随机主机位重配一次
sleep 3
if ip -6 addr show dev "$DEV" 2>/dev/null | grep -q dadfailed; then
	rand=$(awk 'BEGIN{srand(); printf "%x", int(rand()*65534) + 1}')
	uci set network.lan6.ip6addr="$prefix::$rand/64"
	uci commit network
	log "地址冲突,改用 $prefix::$rand/64"
	ifup lan6 >/dev/null 2>&1 || ubus call network.interface.lan6 up >/dev/null 2>&1
fi

/etc/init.d/odhcpd reload >/dev/null 2>&1 || /etc/init.d/odhcpd restart >/dev/null 2>&1
log "完成:LAN IPv6 $(uci -q get network.lan6.ip6addr),RA/DHCPv6 已开,DNS 只发本机"
exit 0
