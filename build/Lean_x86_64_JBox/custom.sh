#!/bin/bash

# 安装额外依赖软件包
# sudo -E apt-get -y install rename

# 更新feeds文件
# sed -i 's@#src-git helloworld@src-git helloworld@g' feeds.conf.default # 启用helloworld
# sed -i 's@src-git luci@# src-git luci@g' feeds.conf.default # 禁用18.06Luci
# sed -i 's@## src-git luci@src-git luci@g' feeds.conf.default # 启用23.05Luci
cat feeds.conf.default

# 添加第三方软件包
AOXI_PACKAGE_COMMIT="aa16dabe81cb46f57572baf689bf69782ce53dd7"
git clone --no-checkout https://github.com/aoxijy/aoxi-package.git package/aoxi-package
git -C package/aoxi-package checkout --detach "$AOXI_PACKAGE_COMMIT"
test "$(git -C package/aoxi-package rev-parse HEAD)" = "$AOXI_PACKAGE_COMMIT"

# 更新并安装源
./scripts/feeds clean
./scripts/feeds update -a && ./scripts/feeds install -a -f

# 在“状态 → 概况”底部加入服务菜单显示/隐藏开关（默认隐藏）
bash build/scripts/luci-service-menu-toggle/install.sh

# 将 J-Box 官方发布包校验后直接集成进固件(集成脚本每次编译自动解析并拉取 J-Box 最新 release)
bash build/scripts/jbox/install.sh

# 修复 LEDE 源码: iptables-nft 依赖未定义的 Kconfig 符号 IPTABLES_NFTABLES,
# 导致 make defconfig 时 CONFIG_PACKAGE_iptables-nft 被静默丢弃(固件只有 legacy iptables),
# dockerd 写入 legacy 规则与 fw4(nftables) 混合, LuCI 报"检测到旧版规则"警告。
# 这里强制开启 nftables 支持并移除未定义符号依赖, 让 iptables-nft 正常编译。
sed -i 's/DEPENDS:=iptables @IPTABLES_NFTABLES +libxtables-nft/DEPENDS:=iptables +libxtables-nft/' package/network/utils/iptables/Makefile
sed -i 's/DEPENDS:=ip6tables @IPTABLES_NFTABLES +libxtables-nft/DEPENDS:=ip6tables +libxtables-nft/' package/network/utils/iptables/Makefile
sed -i 's/+IPTABLES_NFTABLES:libnftnl/+libnftnl/' package/network/utils/iptables/Makefile
sed -i 's/\$(if \$(CONFIG_IPTABLES_NFTABLES),,--disable-nftables)/--enable-nftables/' package/network/utils/iptables/Makefile
# 校验补丁是否生效
if grep -q "@IPTABLES_NFTABLES\|--disable-nftables" package/network/utils/iptables/Makefile; then
    echo "警告: iptables-nft 源码补丁未完全生效, 请检查 package/network/utils/iptables/Makefile"
else
    echo "iptables-nft 源码补丁已生效"
fi

# 开启内核 NFT_COMPAT(xtables 兼容层): iptables-nft 处理 addrtype 等 xtables 扩展时必需。
# LEDE 在 kmod-nft-core 里强制 CONFIG_NFT_COMPAT=n, 且缺失 NFT_COMPAT-m/KCONFIG_NFT_COMPAT
# 变量定义, 导致 nft_compat.ko 永远编译不出来、kmod-nft-compat 包为空壳。
# 修复: 移除强制禁用 + 补变量定义 + 修正包依赖(官方 kmod-nf-ipt 在 LEDE 中为 kmod-ipt-core)。
sed -i '/^[[:space:]]*CONFIG_NFT_COMPAT=n[[:space:]]*\\$/d' package/kernel/linux/modules/netfilter.mk
sed -i 's/DEPENDS:=+kmod-nft-core +kmod-nf-ipt/DEPENDS:=+kmod-nft-core +kmod-ipt-core/' package/kernel/linux/modules/netfilter.mk
if ! grep -q "^NFT_COMPAT-m" package/kernel/linux/modules/netfilter.mk; then
    sed -i '/^define KernelPackage\/nft-compat$/i NFT_COMPAT-m = netfilter/nft_compat\nKCONFIG_NFT_COMPAT = CONFIG_NFT_COMPAT' package/kernel/linux/modules/netfilter.mk
fi
# 校验补丁是否生效
if grep -q "CONFIG_NFT_COMPAT=n" package/kernel/linux/modules/netfilter.mk; then
    echo "警告: NFT_COMPAT 补丁未完全生效, 请检查 package/kernel/linux/modules/netfilter.mk"
else
    echo "NFT_COMPAT 补丁已生效(kmod-nft-compat 可用)"
fi

# 删除部分默认包
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash \
       package/feeds/luci/luci-app-openclash \
       package/aoxi-package/luci-app-openclash \
       package/aoxi-package/*/luci-app-openclash
rm -rf feeds/luci/themes/luci-theme-argon

# 创建预安装目录和脚本
echo "创建预安装目录和脚本..."
mkdir -p files/etc/pre_install
mkdir -p files/etc/uci-defaults

# 创建预安装脚本
cat > files/etc/uci-defaults/98-pre_install << 'EOF'
#!/bin/sh

PKG_DIR="/etc/pre_install"

if [ -d "$PKG_DIR" ] && [ -n "$(ls -A $PKG_DIR 2>/dev/null)" ]; then

    echo "开始安装预置IPK包..."

    # 第一阶段：优先安装架构特定的包 (e.g., npc_0.26.26-r16_x86_64.ipk)
    for pkg in $PKG_DIR/*x86_64.ipk; do
        if [ -f "$pkg" ]; then
            echo "优先安装基础包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第二阶段：安装所有架构通用的包 (e.g., luci-app-npc_all.ipk)
    for pkg in $PKG_DIR/*_all.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 第三阶段：安装语言包 (e.g., luci-i18n-easytier_zh-cn.ipk)
    for pkg in $PKG_DIR/*_zh-cn.ipk; do
        if [ -f "$pkg" ]; then
            echo "安装LuCI应用包: $(basename "$pkg")"
            opkg install "$pkg" --force-depends
        fi
    done

    # 清理现场
    echo "预安装完成，清理临时文件..."
    rm -rf $PKG_DIR
fi

exit 0
EOF

# 设置预安装脚本权限
chmod +x files/etc/uci-defaults/98-pre_install

# 创建首次启动脚本: 统一 iptables/ip6tables 到 nftables 后端
# 背景: 系统防火墙 fw4 使用 nftables, 而 dockerd 调用 iptables 默认走 legacy 后端,
#       产生 legacy+nft 混合规则, LuCI 状态->防火墙 报"检测到旧版规则"警告。
# 方案: 1) iptables* 命令重定向到 xtables-nft-multi(nft 后端), 规则全部进 nftables
#       2) 清空 legacy 表并保留 iptables-legacy-save, 供 LuCI 检测(空表不报警)
# 执行时机: uci-defaults(S95done) 先于 dockerd(S99) 启动, 保证 dockerd 直接走 nft 后端
cat > files/etc/uci-defaults/99-iptables-nft << 'EOF'
#!/bin/sh
if [ -x /usr/sbin/xtables-nft-multi ]; then
    for c in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
        [ -e "/usr/sbin/$c" ] && ln -sf xtables-nft-multi "/usr/sbin/$c"
    done
    if [ -x /usr/sbin/xtables-legacy-multi ]; then
        for t in raw mangle nat filter; do
            /usr/sbin/xtables-legacy-multi iptables -t "$t" -F 2>/dev/null
            /usr/sbin/xtables-legacy-multi ip6tables -t "$t" -F 2>/dev/null
        done
        /usr/sbin/xtables-legacy-multi iptables -X 2>/dev/null
        /usr/sbin/xtables-legacy-multi ip6tables -X 2>/dev/null
        ln -sf xtables-legacy-multi /usr/sbin/iptables-legacy-save
        ln -sf xtables-legacy-multi /usr/sbin/ip6tables-legacy-save
    fi
fi
exit 0
EOF
chmod +x files/etc/uci-defaults/99-iptables-nft

# 创建首次启动脚本: 随机生成主机名 + npc vkey + easytier UUID
# 注意: 不能放 /etc/uci-defaults(S10boot 内, 先于 config_generate 执行),
#       config_generate 会重建 system 配置覆盖 hostname; 且 uci-defaults 阶段
#       pre_install 的 easytier ipk 尚未安装, config.toml 不存在。
# 方案: 放 /etc/rc.local(S95done 执行, 晚于 config_generate 与 pre_install),
#       加首次启动标记, 仅刷机安装后第一次开机执行。
cat > files/etc/rc.local << 'EOF'
#!/bin/sh
# 首次启动生成随机身份: 主机名 GQRU-XXXX + npc vkey + easytier instance_id(UUID)
if [ ! -f /etc/.identity-generated ]; then
    HOST="GQRU-$(head -c 8 /dev/urandom | md5sum | cut -c1-4 | tr 'a-f' 'A-F')"
    uci set system.@system[0].hostname="$HOST"
    uci commit system
    echo "$HOST" > /proc/sys/kernel/hostname

    # NPS 客户端唯一验证密钥(vkey) = 随机主机名
    uci set npc.@npc[0].vkey="$HOST"
    uci commit npc

    # easytier 节点 UUID(仅 instance_id 随机, 网络身份保持不变)
    UUID=$(head -c 64 /dev/urandom | md5sum | cut -d' ' -f1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    if [ -f /etc/easytier/config.toml ] && grep -q '^instance_id' /etc/easytier/config.toml; then
        sed -i "s/^instance_id = .*/instance_id = \"$UUID\"/" /etc/easytier/config.toml
    fi
    touch /etc/.identity-generated
fi
exit 0
EOF
chmod +x files/etc/rc.local

# 自定义定制选项
NET="package/base-files/files/bin/config_generate"   # 修正路径
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 读取内核版本
KERNEL_PATCHVER=$(cat target/linux/x86/Makefile | grep KERNEL_PATCHVER | sed 's/^.\{17\}//g')
KERNEL_TESTING_PATCHVER=$(cat target/linux/x86/Makefile | grep KERNEL_TESTING_PATCHVER | sed 's/^.\{25\}//g')
if [[ $KERNEL_TESTING_PATCHVER > $KERNEL_PATCHVER ]]; then
    # 转义点号避免正则解析问题
    sed -i "s/${KERNEL_PATCHVER//./\\.}/${KERNEL_TESTING_PATCHVER//./\\.}/g" target/linux/x86/Makefile
    echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
else
    echo "内核版本不需要更新"
fi

# 修改默认配置
sed -i 's#LEDE#OpenWrt-GanQuanRu#g' $NET
sed -i 's@.*CYXluq4wUazHjmCDBCqXF*@#&@g' $ZZZ
sed -i "s/LEDE /GanQuanRu build $(TZ=UTC-8 date "+%Y.%m.%d") @ LEDE /g" $ZZZ
echo "uci set luci.main.mediaurlbase=/luci-static/argon" >> $ZZZ

# 修改时间格式等
sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' package/lean/autocore/files/*/index.htm
sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner

# 添加网络设置到 zzz-default-settings
cat >> $ZZZ <<-EOF
# 设置网络-旁路由模式
uci set network.lan.ipaddr='172.18.18.222'
uci set network.lan.gateway='172.18.18.2'                     # 旁路由设置 IPv4 网关
uci set network.lan.dns='223.5.5.5 119.29.29.29'            # 旁路由设置 DNS(多个DNS要用空格分开)
uci set dhcp.lan.ignore='1'                                  # 旁路由关闭DHCP功能
uci delete network.lan.type                                  # 旁路由桥接模式-禁用
uci set network.lan.delegate='0'                             # 旁路由与上游共用同一个 /64,不向上游要前缀
uci set dhcp.@dnsmasq[0].filter_aaaa='0'                     # 不拦 AAAA:走代理的域名由 J-Box 自己回空

# 设置防火墙-旁路由模式
uci set firewall.@defaults[0].syn_flood='0'                  # 禁用 SYN-flood 防御
uci set firewall.@defaults[0].flow_offloading='0'           # 禁用基于软件的NAT分载
uci set firewall.@defaults[0].flow_offloading_hw='0'       # 禁用基于硬件的NAT分载
uci set firewall.@defaults[0].fullcone='1'                   # 启用 FullCone NAT (NAT1)
uci set firewall.@defaults[0].fullcone6='0'                  # 禁用 FullCone NAT6
uci set firewall.@zone[0].masq='1'                             # 启用LAN口 IP 动态伪装

# 旁路由 IPv6:LAN 侧开 RA/DHCPv6,客户端 DNS 只发本机(odhcpd 的 dns 默认就是接口自己的地址),
# 不发上游/公共 DNS —— 否则 IPv6 这条路会绕开本机解析,拿到的是被污染的结果。ndp 保持 disabled,
# 不把上游 RA 里的前缀 / DNS 代答下去。上游 /64 与默认路由先给一套现网默认值,开机由
# /usr/libexec/jbox-ipv6-lan.sh 按网段实际情况自动校正(见 build/scripts/jbox/ipv6-lan.sh)。
uci set dhcp.lan.ra='server'                                  # 路由通告服务-开
uci set dhcp.lan.dhcpv6='server'                              # DHCPv6 服务-开
uci set dhcp.lan.ra_management='2'                            # DHCPv6 模式:有状态分配地址
uci set dhcp.lan.ra_preference='high'                         # 客户端优先用本机当 v6 网关
uci set dhcp.lan.ra_dns='1'                                   # RA 里带 RDNSS
# ra_default=1:接口上没有公网地址时**不发默认路由**。odhcpd 默认是 0——即使本机没有公网 v6
# 也会把自己当 v6 网关发出去,客户端的 v6 就全进这台机器然后没处去(网页会先试 v6、卡一下才回退 v4)。
# 没有公网 IPv6 / 主路由不发 v6 的网络里,这条保证本机不会变成 v6 黑洞;有前缀时照常发。
uci set dhcp.lan.ra_default='1'
uci set dhcp.lan.ndp='disabled'                               # 不代答上游 RA,不把上游前缀/DNS 带下去
uci set network.lan6=interface
uci set network.lan6.device='br-lan'
uci set network.lan6.proto='static'
uci set network.lan6.ip6addr='240e:351:3724:d101::2/64'       # 现网默认,开机自动校正
uci set network.lan6.ip6gw='fe80::20c:29ff:fe6c:9458'         # 上游主路由的链路本地地址
uci set network.lan6.jbox_auto='1'                            # 标记:这一节由开机自检脚本维护
uci set firewall.@zone[0].network='lan'                       # lan6 与 lan 共用 br-lan,同一个 zone

uci commit dhcp
uci commit network
uci commit firewall

# easytier - Web配置模式(默认不启动, 服务器地址不预置防泄露, 由用户在 LuCI 填写)
uci set easytier.@easytier[0].etcmd='web'

# NPS 内网穿透客户端(默认关闭, vkey=随机主机名 由首次启动脚本生成, 服务器地址不预置防泄露)
uci set npc.@npc[0].enable='0'

uci commit easytier
uci commit npc

EOF

# =======================================================
# 开始生成 .config
# =======================================================
cd "$HOME"   # 回到 openwrt 根目录

# 清空现有 .config（如果存在）
rm -f .config

# 编译x64固件:
cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
EOF

# 设置固件大小:
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=16
CONFIG_TARGET_ROOTFS_PARTSIZE=1024
EOF

# 同时生成SquashFS和ext4固件
# cat >> .config <<EOF
# CONFIG_TARGET_ROOTFS_SQUASHFS=y
# CONFIG_TARGET_ROOTFS_EXT4FS=y
# CONFIG_TARGET_EXT4_ROOTFS_PARTSIZE=720
# EOF

# 固件压缩:
cat >> .config <<EOF
CONFIG_TARGET_IMAGES_GZIP=y
EOF

# 编译UEFI固件:
cat >> .config <<EOF
CONFIG_EFI_IMAGES=y
EOF

# IPv6支持:
cat >> .config <<EOF
CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y
CONFIG_PACKAGE_ipv6helper=y
EOF

# 编译PVE/KVM、Hyper-V、VMware镜像以及镜像填充
cat >> .config <<EOF
# CONFIG_QCOW2_IMAGES is not set
# CONFIG_VHDX_IMAGES is not set
CONFIG_VMDK_IMAGES=y
CONFIG_TARGET_IMAGES_PAD=y
EOF

# 多文件系统支持（注释掉的示例，不启用）
# cat >> .config <<EOF
# CONFIG_PACKAGE_kmod-fs-nfs=y
# CONFIG_PACKAGE_kmod-fs-nfs-common=y
# CONFIG_PACKAGE_kmod-fs-nfs-v3=y
# CONFIG_PACKAGE_kmod-fs-nfs-v4=y
# CONFIG_PACKAGE_kmod-fs-ntfs=y
# CONFIG_PACKAGE_kmod-fs-squashfs=y
# EOF

# USB3.0支持（注释掉的示例，不启用）
# cat >> .config <<EOF
# CONFIG_PACKAGE_kmod-usb-ohci=y
# CONFIG_PACKAGE_kmod-usb-ohci-pci=y
# CONFIG_PACKAGE_kmod-usb2=y
# CONFIG_PACKAGE_kmod-usb2-pci=y
# CONFIG_PACKAGE_kmod-usb3=y
# EOF

# 多线多拨（注释掉的示例，不启用）
# cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-syncdial=y
# CONFIG_PACKAGE_luci-app-mwan3=y
# # CONFIG_PACKAGE_luci-app-mwan3helper is not set
# EOF

# 第三方插件选择:
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-oaf is not set
# CONFIG_PACKAGE_luci-app-openclash is not set
# CONFIG_PACKAGE_luci-app-nikki is not set
# CONFIG_PACKAGE_luci-app-serverchan is not set
# CONFIG_PACKAGE_luci-app-eqos is not set
# CONFIG_PACKAGE_luci-app-easytier is not set
# CONFIG_PACKAGE_luci-app-control-weburl is not set
# CONFIG_PACKAGE_luci-app-smartdns is not set
# CONFIG_PACKAGE_luci-app-adguardhome is not set
# CONFIG_PACKAGE_luci-app-poweroff is not set
# CONFIG_PACKAGE_luci-app-argon-config is not set
# CONFIG_PACKAGE_luci-app-autotimeset is not set
# CONFIG_PACKAGE_luci-app-ddnsto is not set
# CONFIG_PACKAGE_ddnsto is not set
EOF

# ShadowsocksR插件:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-ssr-plus=y
# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_SagerNet_Core is not set
EOF

# Passwall插件:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-passwall=y
# CONFIG_PACKAGE_luci-app-passwall2 is not set
# CONFIG_PACKAGE_naiveproxy is not set
CONFIG_PACKAGE_chinadns-ng=y
# CONFIG_PACKAGE_brook is not set
CONFIG_PACKAGE_trojan-go=y
CONFIG_PACKAGE_xray-plugin=y
# CONFIG_PACKAGE_shadowsocks-rust-sslocal is not set
EOF

# Turbo ACC 网络加速:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-turboacc_INCLUDE_NFT_FULLCONE=y
CONFIG_PACKAGE_kmod-nft-fullcone=y
EOF

# 常用LuCI插件:
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-adbyby-plus is not set
# CONFIG_PACKAGE_luci-app-webadmin is not set
# CONFIG_PACKAGE_luci-app-ddns is not set
# CONFIG_PACKAGE_luci-app-vlmcsd is not set
CONFIG_PACKAGE_luci-app-filetransfer=y
# CONFIG_PACKAGE_luci-app-autoreboot is not set
# CONFIG_PACKAGE_luci-app-upnp is not set
# CONFIG_PACKAGE_luci-app-arpbind is not set
# CONFIG_PACKAGE_luci-app-accesscontrol is not set
# CONFIG_PACKAGE_luci-app-wol is not set
# CONFIG_PACKAGE_luci-app-nps is not set
# CONFIG_PACKAGE_luci-app-frpc is not set
# CONFIG_PACKAGE_luci-app-nlbwmon is not set
CONFIG_PACKAGE_luci-app-wrtbwmon=y
# CONFIG_PACKAGE_luci-app-haproxy-tcp is not set
# CONFIG_PACKAGE_luci-app-diskman is not set
# CONFIG_PACKAGE_luci-app-transmission is not set
# CONFIG_PACKAGE_luci-app-qbittorrent is not set
# CONFIG_PACKAGE_luci-app-amule is not set
# CONFIG_PACKAGE_luci-app-xlnetacc is not set
# CONFIG_PACKAGE_luci-app-zerotier is not set
# CONFIG_PACKAGE_luci-app-hd-idle is not set
# CONFIG_PACKAGE_luci-app-unblockmusic is not set
# CONFIG_PACKAGE_luci-app-airplay2 is not set
# CONFIG_PACKAGE_luci-app-music-remote-center is not set
# CONFIG_PACKAGE_luci-app-usb-printer is not set
# CONFIG_PACKAGE_luci-app-sqm is not set
# CONFIG_PACKAGE_luci-app-jd-dailybonus is not set
# CONFIG_PACKAGE_luci-app-uugamebooster is not set
# CONFIG_PACKAGE_luci-app-dockerman is not set
# CONFIG_PACKAGE_luci-app-ttyd is not set
# CONFIG_PACKAGE_luci-app-wireguard is not set
EOF

# VPN相关插件(禁用):
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-v2ray-server is not set
# CONFIG_PACKAGE_luci-app-pptp-server is not set
# CONFIG_PACKAGE_luci-app-ipsec-vpnd is not set
# CONFIG_PACKAGE_luci-app-openvpn-server is not set
# CONFIG_PACKAGE_luci-app-softethervpn is not set
EOF

# 文件共享相关(禁用):
cat >> .config <<EOF
# CONFIG_PACKAGE_luci-app-minidlna is not set
# CONFIG_PACKAGE_luci-app-vsftpd is not set
# CONFIG_PACKAGE_luci-app-samba is not set
# CONFIG_PACKAGE_autosamba is not set
# CONFIG_PACKAGE_samba36-server is not set
EOF

# LuCI主题:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-theme-argon=y
# CONFIG_PACKAGE_luci-theme-design is not set
EOF

# 常用软件包:
cat >> .config <<EOF
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_kmod-nft-compat=y
# CONFIG_PACKAGE_firewall is not set
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
# CONFIG_PACKAGE_screen is not set
# CONFIG_PACKAGE_tree is not set
# CONFIG_PACKAGE_vim-fuller is not set
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_snmpd=y
CONFIG_PACKAGE_libcap=y
CONFIG_PACKAGE_libcap-bin=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_vsftpd=y
CONFIG_PACKAGE_openssh-sftp-server=y
CONFIG_PACKAGE_qemu-ga=y
CONFIG_PACKAGE_autocore-x86=y
EOF

# 其他软件包:
cat >> .config <<EOF
CONFIG_HAS_FPU=y
EOF

# 去除行首空格
sed -i 's/^[ \t]*//g' ./.config

# 修复和调试
echo "=== 原始配置行数: $(wc -l .config) ==="
echo "=== 第30-70行内容 ==="
sed -n '30,70p' .config

# 自动修复常见语法错误
sed -i 's/^\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+\([^=]\)/\1=\2/g' .config
sed -i 's/^[[:space:]]*#*[[:space:]]*\(CONFIG_[A-Z0-9_]*\)[[:space:]]\+is not set/# \1 is not set/g' .config
sed -i '/^[[:space:]]*$/d' .config

echo "=== 修复后的第30-70行内容 ==="
sed -n '30,70p' .config
echo "=== 修复完成 ==="

# 禁止包含 OpenClash：若依赖解析将它重新启用，直接停止编译，避免产生混装固件。
# OPENCLASH_FORBIDDEN
if grep -Eqi '^CONFIG_PACKAGE_.*openclash=y$' .config; then
    echo "错误: J-Box 目标检测到 OpenClash 被启用，拒绝继续编译。"
    grep -Ei '^CONFIG_PACKAGE_.*openclash=y$' .config
    exit 1
fi
rm -rf files/etc/openclash files/usr/share/openclash files/etc/uci-defaults/*openclash*

# 修改退出命令到最后（确保 exit 0 存在）
cd "$HOME"
sed -i '/exit 0/d' $ZZZ
echo "exit 0" >> $ZZZ

# 返回目录（可选）
cd $HOME
