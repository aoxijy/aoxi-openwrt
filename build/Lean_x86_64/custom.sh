#!/bin/bash

# 安装额外依赖软件包
# sudo -E apt-get -y install rename

# 更新feeds文件
# sed -i 's@#src-git helloworld@src-git helloworld@g' feeds.conf.default # 启用helloworld
# sed -i 's@src-git luci@# src-git luci@g' feeds.conf.default # 禁用18.06Luci
# sed -i 's@## src-git luci@src-git luci@g' feeds.conf.default # 启用23.05Luci
cat feeds.conf.default

# 添加第三方软件包
git clone https://github.com/aoxijy/aoxi-package.git -b master package/aoxi-package

# 更新并安装源
./scripts/feeds clean
./scripts/feeds update -a && ./scripts/feeds install -a -f

# 强制删除 ksmbd 相关包
echo "强制删除 ksmbd 相关包..."
rm -rf feeds/luci/applications/luci-app-ksmbd 2>/dev/null || true
rm -rf feeds/packages/net/ksmbd 2>/dev/null || true
rm -rf package/network/services/ksmbd 2>/dev/null || true

# 删除部分默认包
rm -rf feeds/luci/applications/luci-app-qbittorrent
rm -rf feeds/luci/applications/luci-app-openclash
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
    for pkg in $PKG_DIR/*_*.ipk; do
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

    # 清理现场
    echo "预安装完成，清理临时文件..."
    rm -rf $PKG_DIR
fi

exit 0
EOF

# 设置预安装脚本权限
chmod +x files/etc/uci-defaults/98-pre_install

# 下载预安装的IPK包
echo "下载预安装IPK包..."
# 示例：下载npc和luci-app-npc
wget -P files/etc/pre_install/ https://example.com/path/to/npc_0.26.26-r16_x86_64.ipk || echo "npc包下载失败，将继续编译"
wget -P files/etc/pre_install/ https://example.com/path/to/luci-app-npc_all.ipk || echo "luci-app-npc包下载失败，将继续编译"

# 检查下载是否成功
if [ ! -f "files/etc/pre_install/npc_0.26.26-r16_x86_64.ipk" ]; then
    echo "警告: npc包下载失败! 预安装将跳过此包"
fi

if [ ! -f "files/etc/pre_install/luci-app-npc_all.ipk" ]; then
    echo "警告: luci-app-npc包下载失败! 预安装将跳过此包"
fi

# 复制自定义配置文件到files目录
echo "复制自定义配置文件..."
if [ -d "${WORKPATH}/sources/etc" ]; then
    # 创建目标目录
    mkdir -p files/etc
    
    # 复制所有配置文件
    echo "正在从 ${WORKPATH}/sources/etc/ 复制配置文件到 files/etc/"
    cp -rf "${WORKPATH}/sources/etc/"* "files/etc/" 2>/dev/null || true
    
    # 检查复制结果
    echo "配置文件复制完成，检查复制的文件:"
    if [ -d "files/etc/config" ]; then
        echo "- OpenWrt配置文件目录已创建: files/etc/config/"
        echo "  包含文件: $(find files/etc/config -type f | wc -l) 个"
    fi
    
    if [ -d "files/etc/openclash" ]; then
        echo "- OpenClash配置文件目录已创建: files/etc/openclash/"
        echo "  包含文件: $(find files/etc/openclash -type f | wc -l) 个"
    fi
    
    # 显示前几个文件作为示例
    echo "复制的文件示例:"
    find "files/etc" -type f | head -5
else
    echo "警告: 未找到 ${WORKPATH}/sources/etc 目录"
    echo "当前工作目录: $(pwd)"
    echo "目录内容:"
    ls -la "${WORKPATH}/" || echo "无法访问 ${WORKPATH}"
fi

# 自定义定制选项
NET="package/base-files/files/bin/config_generate"
ZZZ="package/lean/default-settings/files/zzz-default-settings"

# 读取内核版本
if [ -f "target/linux/x86/Makefile" ]; then
    KERNEL_PATCHVER=$(grep KERNEL_PATCHVER target/linux/x86/Makefile | awk -F '=' '{print $2}' | tr -d ' ')
    KERNEL_TESTING_PATCHVER=$(grep KERNEL_TESTING_PATCHVER target/linux/x86/Makefile | awk -F '=' '{print $2}' | tr -d ' ')
    
    if [ -n "$KERNEL_TESTING_PATCHVER" ] && [ -n "$KERNEL_PATCHVER" ] && [ "$KERNEL_TESTING_PATCHVER" != "$KERNEL_PATCHVER" ]; then
        sed -i "s/KERNEL_PATCHVER := $KERNEL_PATCHVER/KERNEL_PATCHVER := $KERNEL_TESTING_PATCHVER/g" target/linux/x86/Makefile
        echo "内核版本已更新为 $KERNEL_TESTING_PATCHVER"
    else
        echo "内核版本不需要更新"
    fi
else
    echo "警告: 未找到 target/linux/x86/Makefile 文件"
fi

# 修改默认IP
if [ -f "$NET" ]; then
    sed -i 's/192\.168\.1\.1/172.18.18.222/g' "$NET"
    echo "默认IP已修改为 172.18.18.222"
else
    echo "警告: 未找到 $NET 文件"
fi

# 取消系统默认密码
if [ -f "$ZZZ" ]; then
    sed -i 's/.*CYXluq4wUazHjmCDBCqXF*./#&/g' "$ZZZ"
    echo "已取消系统默认密码"
    
    # 增加个性名称
    BUILD_DATE=$(TZ=UTC-8 date "+%Y.%m.%d")
    sed -i "s/LEDE /GanQuanRu build $BUILD_DATE @ LEDE /g" "$ZZZ"
    echo "已添加个性名称: ONE build $BUILD_DATE"
    
    # 设置默认主题
    echo "uci set luci.main.mediaurlbase='/luci-static/argon'" >> "$ZZZ"
    echo "已设置默认主题为 argon"
else
    echo "警告: 未找到 $ZZZ 文件"
fi

# 修改默认时间格式
if [ -d "package/lean/autocore/files" ]; then
    find package/lean/autocore/files -name "index.htm" -exec sed -i 's#localtime  = os.date()#localtime  = os.date("%Y年%m月%d日") .. " " .. translate(os.date("%A")) .. " " .. os.date("%X")#g' {} \;
    echo "已修改默认时间格式"
else
    echo "警告: 未找到 package/lean/autocore/files 目录"
fi

# 自定义banner显示
if [ -f "package/base-files/files/etc/banner" ]; then
    sed -i 's#%D %V, %C#%D %V, %C Lean_x86_64#g' package/base-files/files/etc/banner
    echo "已自定义banner显示"
else
    echo "警告: 未找到 package/base-files/files/etc/banner 文件"
fi

# 强制显示2500M和全双工
if [ -f "package/base-files/files/etc/rc.local" ]; then
    sed -i '/exit 0/i\ethtool -s eth0 speed 10000 duplex full' package/base-files/files/etc/rc.local
    echo "已添加网卡设置到 rc.local"
else
    echo "警告: 未找到 package/base-files/files/etc/rc.local 文件"
fi

# ========================性能跑分========================
if [ -f "$ZZZ" ]; then
    echo "rm -f /etc/uci-defaults/xxx-coremark" >> "$ZZZ"
    cat >> "$ZZZ" <<EOF
cat /dev/null > /etc/bench.log
echo " (CpuMark : 191219.823122" >> /etc/bench.log
echo " Scores)" >> /etc/bench.log
EOF
    echo "已添加性能跑分配置"
fi

# ================ 网络设置 =======================================
if [ -f "$ZZZ" ]; then
    cat >> "$ZZZ" <<EOF
# 设置网络-旁路由模式
uci set network.lan.gateway='172.18.18.2'                  # 旁路由设置 IPv4 网关
uci set network.lan.dns='223.5.5.5 119.29.29.29'          # 旁路由设置 DNS
uci set dhcp.lan.ignore='1'                               # 旁路由关闭DHCP功能
uci delete network.lan.type                               # 旁路由桥接模式-禁用
uci set network.lan.delegate='0'                          # 去掉LAN口使用内置的 IPv6 管理
uci set dhcp.@dnsmasq[0].filter_aaaa='0'                  # 禁止解析 IPv6 DNS记录

# 设置防火墙-旁路由模式
uci set firewall.@defaults[0].syn_flood='0'               # 禁用 SYN-flood 防御
uci set firewall.@defaults[0].flow_offloading='0'         # 禁用基于软件的NAT分载
uci set firewall.@defaults[0].flow_offloading_hw='0'      # 禁用基于硬件的NAT分载
uci set firewall.@defaults[0].fullcone='0'                # 禁用 FullCone NAT
uci set firewall.@defaults[0].fullcone6='0'               # 禁用 FullCone NAT6
uci set firewall.@zone[0].masq='1'                        # 启用LAN口 IP 动态伪装

# 旁路IPV6需要全部禁用
uci del network.lan.ip6assign                             # IPV6分配长度-禁用
uci del dhcp.lan.ra                                       # 路由通告服务-禁用
uci del dhcp.lan.dhcpv6                                   # DHCPv6 服务-禁用
uci del dhcp.lan.ra_management                            # DHCPv6 模式-禁用

uci commit dhcp
uci commit network
uci commit firewall
EOF
    echo "已添加旁路由网络设置"
fi

# 检查 OpenClash 是否启用编译
if [ -f ".config" ] && grep -q "CONFIG_PACKAGE_luci-app-openclash=y" .config; then
    echo "OpenClash 已启用编译"
    
    # 判断系统架构
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            arch="unknown"
            ;;
    esac
    
    if [ "$arch" != "unknown" ]; then
        echo "正在为OpenClash下载 $arch 架构的内核"
        
        # 创建目录
        mkdir -p files/etc/openclash/core
        
        # 下载Meta内核
        if wget -q -O /tmp/clash.tar.gz https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-$arch.tar.gz; then
            echo "OpenClash Meta内核下载成功"
            tar -zxvf /tmp/clash.tar.gz -C /tmp/ >/dev/null 2>&1
            
            if [ -f "/tmp/clash" ]; then
                mv -f /tmp/clash files/etc/openclash/core/clash_meta
                chmod +x files/etc/openclash/core/clash_meta
                echo "OpenClash Meta内核配置成功"
            else
                echo "OpenClash Meta内核解压失败"
            fi
            
            rm -f /tmp/clash.tar.gz
        else
            echo "OpenClash Meta内核下载失败"
        fi
    else
        echo "未知系统架构: $arch，跳过OpenClash内核下载"
    fi
else
    echo "OpenClash 未启用编译"
    if [ -f "$ZZZ" ]; then
        echo 'rm -rf /etc/openclash' >> "$ZZZ"
    fi
fi

# 修改退出命令到最后
if [ -f "$ZZZ" ]; then
    sed -i '/exit 0/d' "$ZZZ"
    echo "exit 0" >> "$ZZZ"
fi

# 创建自定义配置文件
touch .config

# 编译x64固件:
cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
EOF

# 设置固件大小:
cat >> .config <<EOF
CONFIG_TARGET_KERNEL_PARTSIZE=16
CONFIG_TARGET_ROOTFS_PARTSIZE=360
EOF

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
CONFIG_QCOW2_IMAGES=n
CONFIG_VHDX_IMAGES=n
CONFIG_VMDK_IMAGES=n
CONFIG_TARGET_IMAGES_PAD=y
EOF

# 第三方插件选择:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-openclash=y #OpenClash客户端
CONFIG_PACKAGE_luci-app-nikki=y #nikki 客户端
# CONFIG_PACKAGE_luci-app-powerof is not set
CONFIG_PACKAGE_luci-app-ssr-plus=y
CONFIG_PACKAGE_luci-app-passwall=y
CONFIG_PACKAGE_luci-app-easytier=y
# CONFIG_PACKAGE_luci-app-npc is not set
# CONFIG_PACKAGE_luci-app-arpbind is not set
# CONFIG_PACKAGE_luci-app-upnp is not set
# CONFIG_PACKAGE_luci-app-ddns is not set
# CONFIG_PACKAGE_luci-app-vlmcsd is not set
# CONFIG_PACKAGE_luci-app-wol is not set
# CONFIG_PACKAGE_luci-app-access-control is not set
# CONFIG_PACKAGE_luci-app-shutdown is not set
CONFIG_PACKAGE_luci-app-ksmbd=n
# CONFIG_PACKAGE_luci-app-vsftpd is not set
# CONFIG_PACKAGE_luci-i18n-ksmbd-zh-cn is not set
# CONFIG_PACKAGE_luci-app-nlbwmon is not set
# CONFIG_PACKAGE_luci-i18n-nlbwmon-zh-cn is not set
# CONFIG_PACKAGE_luci-app-accesscontrol is not set
CONFIG_PACKAGE_luci-app-argon=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF

# Passwall插件:
cat >> .config <<EOF
CONFIG_PACKAGE_chinadns-ng=y
CONFIG_PACKAGE_trojan-go=y
CONFIG_PACKAGE_xray-plugin=y
CONFIG_PACKAGE_shadowsocks-rust-sslocal=n
EOF

# Turbo ACC 网络加速:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-app-turboacc=y
EOF

# LuCI主题:
cat >> .config <<EOF
CONFIG_PACKAGE_luci-theme-argon=y
EOF

# 常用软件包:
cat >> .config <<EOF
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_wget=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_snmpd=y
CONFIG_PACKAGE_libcap=y
CONFIG_PACKAGE_libcap-bin=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_iptables-mod-extra=y
CONFIG_PACKAGE_autoshare-ksmbd=n
CONFIG_PACKAGE_ksmbd=n
CONFIG_PACKAGE_kmod-fs-ksmbd=n
CONFIG_PACKAGE_ksmbd-server=n
CONFIG_PACKAGE_autosamba_INCLUDE_KSMBD=n
# CONFIG_PACKAGE_vsftpd is not set
# CONFIG_PACKAGE_openssh-sftp-server is not set
CONFIG_PACKAGE_qemu-ga=y
CONFIG_PACKAGE_autocore-x86=y
EOF

# 其他软件包:
cat >> .config <<EOF
CONFIG_HAS_FPU=y
EOF

# 清理配置文件格式
sed -i 's/^[ \t]*//g' .config

echo "自定义配置文件创建完成"
