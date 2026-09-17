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

## OpenClash 规则（guize `.mrs`）[![](https://img.shields.io/badge/-OpenClash%20mrs-FFFFFF.svg)](#openclash-规则guize-mrs-)
- 固件已预置 **13 个分类 `.mrs` 规则集**（AI平台 / 社交聊天 / 开发平台 / 国外媒体 / 微软苹果 / 全球直连 / 全球拦截），
  来源 [aoxijy/guize](https://github.com/aoxijy/guize) 的 `mrs-latest` Release，另有本地备份 + 兜底 cron，断网也能启动
- 内核用 **MetaCubeX mihomo**（`v1.19.30`，`format: mrs` 需要 mihomo ≥ 1.18.3），由 `custom.sh` 在编译时下载
- **节点配置不进固件**：镜像里没有任何 Clash 配置，刷完机用 `oc-mrs-import.sh`（U 盘 / 局域网）或 LuCI 上传导入；
  工作流里也没有配置注入入口，`tests/test_no_node_config.py` 会在编译前断言这一点（详见下面「节点配置怎么来」）
- 首次开机由 `/etc/uci-defaults/97-openclash-mrs` 自动完成：打 YAML.rb 补丁 → 铺开规则集备份 → 装兜底 cron → 配置严格模式瘦身
  → 装 MRS 面板入口 → 分组改 `select` 并装选路模型 cron → 生成设备专属随机密钥
- 开箱即用的配置长这样：`rules:` 只有 **13 条 `RULE-SET` + 1 条 `MATCH`**，规则总量 ≈ 4.8 万条全部由 `.mrs` 提供
  （原来 47 111 条内联规则、2.7 MB 的 yaml → 现在 14 条、89 KB）
- 默认已**关闭**「覆写设置 → 启用 GeoIP Dat 版数据库」（`enable_geoip_dat=0`）——规则已经全部走 `.mrs`，不需要 geo 数据
- 默认已**开启**「覆写设置 → DNS 设置 → Fake-IP-Filter」（`custom_fakeip_filter=1` + `blacklist`），并在自定义列表里预置
  `+.gqru.com` / `*.gqru.com` / `+.jgyu.com` / `*.jgyu.com` —— 这几个域名必须走真实 IP，否则 EasyTier 解析不到服务器、连不上
- ⚠️ 已**移除** `GeoIP.dat` / `GeoSite.dat` / `Country.mmdb` / `ASN.mmdb`（每个变体省 46 MB）与
  `.github/workflows/update-geoip.yml` 定时更新：严格模式配置里没有任何 `GEOIP/GEOSITE/IP-ASN` 规则，
  实测把 4 个文件删掉后 `mihomo -t` 依然 successful。以后若要加 GEOIP 规则，联网时 mihomo 会自行下载

### MRS 延迟面板 + 节点选路模型（刷完即用）

固件预置了一整套"延迟记录面板 + 节点自动优选"，首次开机全部自动就位：

| 组件 | 位置 | 作用 |
|---|---|---|
| **MRS 延迟面板** | `http://<路由>:9090/ui/mrs-panel/` | 每个分组的节点表：最新延迟 + **最近 10 次连通记录色条** + 模型得分；**鼠标悬停看这 10 次明细**（时间/延迟/超时）。也可设为默认面板，之后 OpenClash 自己的「控制面板」按钮就打开它 |
| **LuCI 入口** | 服务 → OpenClash → **控制面板**（首页卡片）、**覆写设置 → Dashboard 设置**（可"设为默认面板"） | 首页卡片有 4 个状态点：面板文件 / 选路模型 / 定时任务 / 最近一轮时间与通过率，一眼看出是否生效 |
| **选路模型** | `/etc/openclash/custom/oc-smart.{rb,sh,conf}` | 每 5 分钟给被接管分组的成员测速，每节点保留最近 10 条；按 `延迟 + 2×抖动 + 超时惩罚` 算分，在**每个分组自己的成员里**挑最优（绝不跨组），当前节点没有明显更差就不切 |
| **成员自动适配** | `/etc/openclash/custom/oc-smart-members.rb`（由 overwrite 钩子每次生成配置时调用） | 换订阅/加减节点后自动重建 6 个预设分组的成员：`香港 / 亚洲 / 美国 / 其他` 四组**两两互斥、合并恰好覆盖全部节点**，`自动选择` = 全部，`CHATGPT自动` = 除香港外全部。成员脚本失败会中止本次覆写，避免半更新 |
| **看门狗** | 每 10 分钟 | 状态文件超过 30 分钟没更新（模型挂了）→ 自动把分组交回内核 `url-test` 自管，模型恢复后自动再接管 |
| **分组专用测速地址** | `oc-smart.conf` 的 `GROUP_TEST_URL` | 默认给 `🕸️ CHATGPT自动` 配 `https://chatgpt.com/cdn-cgi/trace` + `expected=200` + 10s 超时（通用地址通了不代表能开 ChatGPT）。回退到 `url-test` 时也会带上这个地址与期望状态码 |

**内置的稳定性设计**

- 测速**同一台服务器串行**（实测 198 个"节点"只对应 93 台服务器，一台最多挂 34 个，并发打同一台会被限速）
- **僵尸节点快速跳过**：实测 198 个节点里 124 个长期连续全失败，每轮都重测纯属浪费。
  连续失败 ≥ `DEAD_STREAK`(3) 次、且在所有参与测速的地址上都不通、且距上次"真正测过"不足复测间隔的节点，
  本轮不再测（成员资格与历史全部保留，`DEAD_PROBE_MINUTES`(25) 分钟到点自动复测，恢复后立刻回候选池）。
  效果：每轮 332 次 → ~125 次，183s → ~120s，把时间让给真正能用的节点
- **只在某一个地址上失败不算僵尸**：有的节点通用地址不通、但 ChatGPT 地址通，这种照常测，不会被误停
- **每组独立状态**：当前节点、上次切换时间、手动让位各自独立；普通分组共用同 URL 的测速结果，但选择范围与防抖互不影响
- **换节点/换整套配置自适应**：成员变动自动跟上；组类型被打回 `url-test` 会自动转回 `select` 并热重载；记录按"测速地址"分桶，离开分组的节点自动清理
- **不跟用户抢**：手动选过的分组让位 5 分钟；`oc-smart.sh select --force` 可强制按模型结果重选
- **并发防撞车**：`oc-smart.sh` 用原子目录锁串行化 cycle/guard/select/watchdog，避免 cron 与手动执行互相覆盖状态
- 规则、脚本、面板全部本地化，**断网也能用**

**常用命令（路由器上）**

```sh
/etc/openclash/custom/oc-smart.sh status            # 每个分组：当前节点 / 得分 / 候选前三
/etc/openclash/custom/oc-smart.sh cycle             # 立刻测一轮并重选
/etc/openclash/custom/oc-smart.sh guard             # 快速守护：只查当前节点，连测两次不通就换（cron 每分钟）
/etc/openclash/custom/oc-smart.sh select --force    # 忽略"手动让位"，强制按模型重选
/etc/openclash/custom/oc-smart.sh type              # 查看被接管分组当前类型（只能是 select，模型才控得住）
/etc/openclash/custom/oc-smart.sh revert            # 交回内核 url-test 自管（仍用专用测速地址）
/etc/openclash/custom/oc-smart.sh watchdog          # 看门狗自检
ruby /etc/openclash/custom/oc-smart-members.rb --check /etc/openclash/config/<配置>.yaml   # 只读校验成员分组
/etc/openclash/custom/oc-luci-panel.rb status       # LuCI 面板 5 项补丁是否就绪（升级 OpenClash 后重跑 install）
tail -f /tmp/openclash_smart.log                    # 模型日志
```

**想给别的分组也配专用测速地址**：在 `/etc/openclash/custom/oc-smart.conf` 里加一行
`GROUP_TEST_URL=组名|地址|期望状态码|超时ms`，然后 `oc-smart.sh --install-cron` 不用重装，下一轮自动生效。

### 节点配置怎么来（🚫 节点一律不进固件）

固件镜像会发布到 **公开的 Releases**，任何人下载后解包就能看到里面的文件。
所以**节点配置绝对不会打进固件**，这已经做成结构性约束，不是"记得别设密钥"：

- 工作流里**没有**任何注入 Clash 配置的步骤（原来的 `OPENCLASH_CONFIG` 入口已删除）；
- 每台设备首启时用 `oc-mrs-import.sh` 从本地导入，或直接在 LuCI 里上传；
- 编译前会跑 `tests/test_no_node_config.py` 断言：交付目录里没有 Clash 配置、
  没有节点协议链接（`vless://` `ss://` …）、没有顶层 `proxies:` / `proxy-groups:`，
  工作流里也不存在配置注入入口 —— 一旦有人加回来，编译直接失败。

刷完机给配置有两种方式：

| 方式 | 说明 |
|---|---|
| **A. 手动导入** | LuCI → OpenClash → 配置文件 → 上传 `zhu5in1.yaml`；或 `scp zhu5in1.yaml root@<路由>:/etc/openclash/config/` 后重载配置 |
| **B. U 盘 / 局域网自动导入** | 把 `zhu5in1.yaml` 放 U 盘根目录（或 U 盘 `/openclash/` 目录），或者把局域网下载地址写进 `/etc/openclash/custom/oc-config-url`（一行 http 地址）；首次开机 `oc-mrs-import.sh` 自动导入，之后再按严格模式瘦身 |
| **C. 要批量刷机** | 用 NAS 上的离线包装好配置（`openclash-fresh-kit-x86_64.tar.gz` 里含私有配置），别再往公开仓库里塞 |

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
