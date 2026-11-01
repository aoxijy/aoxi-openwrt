#!/bin/sh
set -eu
umask 077
die() { echo "ERROR: $*" >&2; exit 1; }
node=${1:-}; profile=${2:-}
case "$node" in 2|8) ;; *) die 'Usage: sh install.sh 2|8 jbox|openclash' ;; esac
case "$profile" in jbox|openclash) ;; *) die 'Choose jbox or openclash' ;; esac
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
p=$base/payload
ip -4 addr show dev br-lan | grep -q "inet 172.18.18.$node/24" || die 'Configure the correct LAN IP /24 on br-lan first'
ip route show default | grep -q 'via 172.18.18.1 dev br-lan' || die 'Default gateway must be 172.18.18.1 on br-lan'
for cmd in keepalived easytier-core easytier-cli npc flock timeout uci; do command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"; done
for svc in easytier npc keepalived dnsmasq "$profile"; do [ -x "/etc/init.d/$svc" ] || die "Missing init service: $svc"; done
for svc in easytier npc; do grep -q '^start_service() {' "/etc/init.d/$svc" || die "Unsupported $svc init format"; done
grep -q 'alt_config_file' /etc/init.d/keepalived || die 'Unsupported keepalived init format'
uci -q get easytier.@easytier[0] >/dev/null || die 'Missing EasyTier UCI section'
[ -s "$p/npc.uci" ] && [ -s "$p/easytier-$node.toml" ] || die 'Missing private payload'
# Verify the selected proxy before making any changes.
if [ "$profile" = jbox ]; then
    command -v capsh >/dev/null || die 'Install libcap-bin for the J-box EasyTier bypass'
    command -v nft >/dev/null || die 'nft is required for J-box'
    grep -q '^jbox_apply_dns_mark() {' /etc/init.d/jbox || die 'Unsupported J-box init: missing DNS mark hook'
    grep -q '^SINGBOX_OUTPUT_MARK=0x2024' /etc/init.d/jbox || die 'Unsupported J-box bypass mark'
    pidof sing-box >/dev/null || die 'Configure and start J-box first'
    ip link show jbox-tun >/dev/null 2>&1 || die 'J-box tun interface is missing'
else
    [ "$(uci -q get openclash.config.enable)" = 1 ] || die 'Enable/configure OpenClash first'
    pidof clash_meta clash >/dev/null || die 'Start the OpenClash core first'
fi
timeout 4 nslookup www.baidu.com 127.0.0.1 >/dev/null 2>&1 || die 'Local DNS is not ready'
[ "${3:-}" != --check ] || { echo "Preflight OK: node .$node, proxy=$profile"; exit 0; }
. "$base/load-identity.sh"
stamp=$(date +%Y%m%d-%H%M%S)
backup=/root/ha-restore-$stamp
mkdir -p "$backup"
set -- /etc/config /etc/init.d /etc/sysupgrade.conf
for f in /etc/easytier /usr/libexec/ha-* /usr/sbin/ha-status /etc/ha-* /etc/keepalived /etc/sysctl.d; do
    [ ! -e "$f" ] || set -- "$@" "$f"
done
tar -czf "$backup/before.tgz" "$@" 2>"$backup/tar.log" || die 'Backup failed'
# Hold this node out of the election until the complete configuration is ready.
touch /tmp/ha-maintenance
/etc/init.d/keepalived stop
/etc/init.d/easytier stop
/etc/init.d/npc stop
mkdir -p /etc/keepalived /etc/easytier /usr/libexec
for f in ha-check ha-role ha-watch; do cp "$p/$f" "/usr/libexec/$f"; chmod 700 "/usr/libexec/$f"; done
cp "$p/ha-status" /usr/sbin/ha-status
chmod 700 /usr/sbin/ha-status
cp "$p/ha-services" /etc/init.d/ha-services
chmod 755 /etc/init.d/ha-services
cp "$p/keepalived-$node.conf" /etc/keepalived/keepalived.conf
cp "$p/easytier-$node.toml" /etc/easytier/config.toml
cp "$p/npc.uci" /etc/config/npc
chmod 600 /etc/keepalived/keepalived.conf /etc/easytier/config.toml /etc/config/npc
echo "$profile" >/etc/ha-proxy-profile
if [ "$profile" = jbox ]; then
    cp "$p/jbox-easytier-core" /usr/libexec/jbox-easytier-core
    chmod 700 /usr/libexec/jbox-easytier-core
    if ! grep -q 'jbox-easytier-core' /etc/init.d/easytier; then
        sed -i 's|cd /tmp ; "${easytierbin}"|cd /tmp ; /usr/libexec/jbox-easytier-core "${easytierbin}"|g' /etc/init.d/easytier
        grep -q 'jbox-easytier-core' /etc/init.d/easytier || die 'Unsupported EasyTier launch line'
    fi
    if ! grep -q 'chain mesh_out' /etc/init.d/jbox; then
        awk -v block="$p/jbox-mesh.block" '{print} /^jbox_apply_dns_mark\(\) \{/ {while ((getline line < block)>0) print line; close(block)}' /etc/init.d/jbox >/tmp/ha-jbox-init.new
        sh -n /tmp/ha-jbox-init.new
        cp /tmp/ha-jbox-init.new /etc/init.d/jbox
        chmod 755 /etc/init.d/jbox
    fi
    # Apply only the bypass chain now; do not restart the proxy.
    nft -f - <<'EOF'
table inet jbox {
    chain mesh_out {
        type route hook output priority -151; policy accept;
    }
}
flush chain inet jbox mesh_out
add rule inet jbox mesh_out meta skgid 20260 counter meta mark set 0x2024
EOF
fi
for svc in easytier npc; do
    if ! grep -q HA_VRRP_GUARD "/etc/init.d/$svc"; then
        sed -i '/^start_service() {/a\
    # HA_VRRP_GUARD\
    if [ -f /etc/ha-router.enabled ] && ! ip -4 addr show dev br-lan | grep -q "inet 172.18.18.18/"; then\
        logger -t ha-router "standby: refusing service start"; return 0\
    fi' "/etc/init.d/$svc"
    fi
done
sed -i 's|procd_set_param command /usr/sbin/keepalived$|procd_set_param command /usr/sbin/keepalived -P|' /etc/init.d/keepalived
uci set keepalived.globals=globals
uci set keepalived.globals.alt_config_file=/etc/keepalived/keepalived.conf
uci commit keepalived
uci set easytier.@easytier[0].etcmd=config
uci set easytier.@easytier[0].enabled=1
uci set easytier.@easytier[0].web_enabled=0
uci set easytier.@easytier[0].et_forward='etfwlan lanfwet'
uci commit easytier
uci set dhcp.lan.ignore=1
uci commit dhcp
cat >/etc/sysctl.d/99-ha-router.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.br-lan.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.br-lan.rp_filter=0
EOF
sysctl -p /etc/sysctl.d/99-ha-router.conf >/dev/null
touch /etc/ha-router.enabled
for svc in easytier npc; do /etc/init.d/$svc disable; sh -n "/etc/init.d/$svc"; done
for svc in "$profile" dnsmasq keepalived ha-services; do /etc/init.d/$svc enable; done
keepalived -t -f /etc/keepalived/keepalived.conf
for f in /usr/libexec/ha-check /usr/libexec/ha-role /usr/libexec/ha-watch; do sh -n "$f"; done
for f in /etc/ha-router.enabled /etc/ha-proxy-profile /etc/ha-quick/identity.conf /etc/keepalived/keepalived.conf /etc/easytier/config.toml /etc/init.d/ha-services /etc/init.d/keepalived /etc/init.d/easytier /etc/init.d/npc /etc/sysctl.d/99-ha-router.conf /usr/libexec/ha-check /usr/libexec/ha-role /usr/libexec/ha-watch /usr/sbin/ha-status; do
    grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >>/etc/sysupgrade.conf
done
if [ "$profile" = jbox ]; then
    for f in /usr/libexec/jbox-easytier-core /etc/init.d/jbox; do
        grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >>/etc/sysupgrade.conf
    done
fi
rm -f /tmp/ha-maintenance
/etc/init.d/ha-services restart
/etc/init.d/keepalived start
echo "Configured node .$node, proxy=$profile, VIP=172.18.18.18. Backup: $backup"
echo 'Wait 20 seconds, then run ha-status. Expected health_exit=0.'
