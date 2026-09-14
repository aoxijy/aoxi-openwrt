<div align="center">
<img width="200" src="https://cdn.jsdelivr.net/gh/Jejz168/Picture/OpenWrt-logo.png"/>
<h1>OpenWrt — Actions</h1>
</div>

## 项目说明 [![](https://img.shields.io/badge/-项目基本介绍-FFFFFF.svg)](#项目说明-)
- 固件来源：[![Lean](https://img.shields.io/badge/Lede-Lean-red.svg?style=flat&logo=appveyor)](https://github.com/coolsnowwolf/lede) 
- 项目使用 Github Actions 拉取 [Lean](https://github.com/coolsnowwolf/lede) [immortalwrt](https://github.com/immortalwrt/immortalwrt) [openwrt](https://github.com/openwrt/openwrt) 的 `Openwrt` 源码仓库进行云编译
  
- ✅x86 固件默认 IP 地址：`172.18.18.222` 默认密码：`无密码`
- ✅x86[Docker] 固件默认 IP 地址：`172.18.18.222` 默认密码：`无密码`
- ✅x86[J-Box] 固件：集成 [J-Box](https://github.com/aoxijy/J-box)，不包含 Docker 和 OpenClash
- ✅x86[J-Box+Docker] 固件：在 J-Box 版基础上增加 Docker，不包含 OpenClash
- 🌐 J-Box 版默认开旁路由 IPv6：LAN 侧发 RA/DHCPv6，**客户端 DNS 只发本机**（不发上游/公共 DNS，避免解析走 IPv6 绕过本机被污染）；上游 `/64` 与默认路由先给一套现网默认值，开机由 `/usr/libexec/jbox-ipv6-lan.sh` 按所在网段自动校正，用户自己配过 IPv6 则完全不接管
- 🛡 没有公网 IPv6 / 主路由不发 v6 也不会出问题：`dhcp.lan.ra_default=1` 保证本机**没有公网地址时不发 v6 默认路由**（否则客户端会把 v6 全送进来再没处去），脚本发现上游没有可用 `/64` 时还会撤掉自建的前缀；整条线路都没有公网 v6 时，把面板里「IPv6」关掉即可（DNS 只回 A、防火墙拦 v6，完全不碰 IPv6）
- 本固件以简洁稳定为主，除必要基础包集合大多数文明上网插件与EasyTier组网。

## 插件预览 [![](https://img.shields.io/badge/-固件插件及功能预览-FFFFFF.svg)](#插件预览-)
- ******此库为单独X86版******
<details>
<summary><b>&nbsp; 插件预览</b></summary>
<br/>
<details>
<summary><b>├── 状态</b></summary>
　├── 概况<br/>
　├── 防火墙<br/>
　├── 路由表<br/>
　├── 系统日志<br/>
　├── 系统进程<br/>
　└── 实时信息<br/>
</details>
<details>
<summary><b>├── 系统</b></summary>
　├── 系统<br/>
　├── 管理权<br/>
　├── 软件包<br/>
　├── 启动项<br/>
　├── 计划任务<br/>
　├── 挂载点<br/>
　├── 磁盘管理<br/>
　├── 备份/升级<br/>
　├── 定时设置<br/>
　├── 文件传输<br/>
　├── Argon 主题设置<br/>
　└── 重启<br/>
</details>
<details>
<summary><b>├── 服务</b></summary>
　├── PassWall<br/>
　├── ShadowSocksR Plus+<br/>
　├── EasyTier<br/>
　├── OpenClash<br/>
　└── Nps 内网穿透<br/>
</details>
<details>
<summary><b>├── 网络</b></summary>
　├── 接口<br/>
　├── 路由<br/>
　├── DHCP/DNS<br/>
　├── 网络诊断<br/>
　├── 防火墙<br/>
　└── Turbo ACC 网络加速<br/>
</details>
　└── <b>退出</b>
</details>

## 固件下载
**点击跳转到该设备固件下载页面**
- ♨️【x86】普通版：Kernel=16 MiB，rootfs=360 MiB；Docker 版：Kernel=32 MiB，rootfs=3000 MiB
- ♨️【x86 J-Box】普通版：Kernel=16 MiB，rootfs=1024 MiB；Docker 版：Kernel=32 MiB，rootfs=3000 MiB
- [**X86版下载地址**](https://github.com/aoxijy/aoxi-openwrt/releases)
- [**X86-docker版下载地址**](https://github.com/aoxijy/aoxi-openwrt/releases)
- [**X86-J-Box版下载地址**](https://github.com/aoxijy/aoxi-openwrt/releases)
- [**X86-J-Box-Docker版下载地址**](https://github.com/aoxijy/aoxi-openwrt/releases)

## 鸣谢 [![](https://img.shields.io/badge/-感谢各大佬-FFFFFF.svg)](#鸣谢-)
| [db-one](https://github.com/db-one/) | [coolsnowwolf](https://github.com/coolsnowwolf) | [P3TERX](https://github.com/P3TERX) | [Jejz168](https://github.com/Jejz168) | [haiibo](https://github.com/haiibo) | [Lenyu2020](https://github.com/Lenyu2020) |
| :-------------: | :-------------: | :-------------: | :-------------: | :-------------: | :-------------: |
| <img width="50" src="https://avatars.githubusercontent.com/u/20243226"/> | <img width="50" src="https://avatars.githubusercontent.com/u/31687149"/> | <img width="50" src="https://avatars.githubusercontent.com/u/25927179"/> | <img width="50" src="https://avatars.githubusercontent.com/u/53441247"/> | <img width="50" src="https://avatars.githubusercontent.com/u/85640068"/> | <img width="50" src="https://avatars.githubusercontent.com/u/59961153"/> |
| [Ophub](https://github.com/ophub) | [Jerrykuku](https://github.com/jerrykuku) | [QiuSimons](https://github.com/QiuSimons) | [IvanSolis1989](https://github.com/IvanSolis1989) | [DHDAXCW](https://github.com/DHDAXCW) | [breakings](https://github.com/breakings) |
| <img width="50" src="https://avatars.githubusercontent.com/u/68696949"/> | <img width="50" src="https://avatars.githubusercontent.com/u/9485680"/> | <img width="50" src="https://avatars.githubusercontent.com/u/45143996"/> | <img width="50" src="https://avatars.githubusercontent.com/u/44228691"/> | <img width="50" src="https://avatars.githubusercontent.com/u/74764072"/> | <img width="50" src="https://avatars.githubusercontent.com/u/25475074"/> |


# 访问量

![](https://komarev.com/ghpvc/?username=Jejz168&color=orange&style=for-the-badge)
# ==============================
# 🏖Special thanks（特别感谢）
- [GitHub Actions](https://github.com/features/actions)🎉🎉Thank you very much.🎉🎉



<a href="#readme">
<img src="https://img.shields.io/badge/-返回顶部-FFFFFF.svg" title="返回顶部" align="right"/>
</a>
