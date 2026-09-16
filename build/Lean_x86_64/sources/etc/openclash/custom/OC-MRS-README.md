# OpenClash + guize `.mrs` 规则集瘦身方案

面向路由器 `172.18.18.2`（OpenWrt 24.10.5 x86_64 / OpenClash 0.47.156 / Mihomo Meta alpha-ge183c58）。

## 1. 结论：怎么在 OpenClash 里用 `.mrs` 当规则

Mihomo（OpenClash 的 Meta 内核）从 1.18 起原生支持 `.mrs` 规则集，写法就是普通的
`rule-providers` + `RULE-SET`，关键是三行：

```yaml
rule-providers:
  ai-platform-domain:
    type: http                 # file / http
    behavior: domain           # 分类规则集固定 domain；IP 段固定 ipcidr
    format: mrs                # ← 不写这行 mihomo 会按 yaml 解析 .mrs，直接报错
    url: https://github.com/aoxijy/guize/releases/latest/download/ai-platform-domain.mrs
    path: ./rule_provider/ai-platform-domain.mrs   # 相对 OpenClash 工作目录 /etc/openclash
    interval: 86400

rules:
  - RULE-SET,ai-platform-domain,🤖 AI平台
  - RULE-SET,ai-platform-ipcidr,🤖 AI平台,no-resolve   # ipcidr 规则集建议加 no-resolve
```

要点：

| 事项 | 说明 |
|---|---|
| `format: mrs` | **必须写**，否则按 yaml 解析失败 |
| `behavior` | `*-domain.mrs` → `domain`；`*-ipcidr.mrs` → `ipcidr`（要和文件匹配，否则报错） |
| `path` | 相对 mihomo 工作目录（OpenClash 是 `/etc/openclash`）；`type: http` 也会把文件缓存在这里，**本地有缓存时即使 GitHub 不通也能启动** |
| `interval` | 秒；mihomo 后台自动更新，失败不影响已有缓存 |
| `type: file` | 只想离线用就写 `type: file` + `path`，不写 url/interval |
| `no-resolve` | ipcidr 规则集后面加，避免为了匹配 IP 规则去反查 DNS |

`.mrs` 里 **装不下** 的规则类型：`DOMAIN-KEYWORD`、`PROCESS-NAME`、`GEOIP`、`MATCH`、IP-ASN 等，
必须留在主配置的 `rules:` 里（本仓库的 `unsupported-classical-only.list` 就是这些）。

### ⚠️ 域名写法坑（已在本仓库修复）

mihomo 的 `behavior: domain` 规则集里：

| payload | 匹配 `openai.com` | 匹配 `api.openai.com` |
|---|---|---|
| `openai.com` | ✅ | ❌ |
| `.openai.com` | ❌ | ✅ |
| `+.openai.com` | ✅ | ✅ |

所以 `DOMAIN-SUFFIX` 必须编译成 `+.域名`。仓库原来的 `update_mrs.py` 写的是 `.域名`，
顶级域名全部漏匹配（实测 `openai.com`/`baidu.com` 都掉到 `MATCH` 兜底）。
已在 commit `f3254a7` 修复，并让 `sources/base/*-domain.txt` 里以 `.` 开头的条目统一补成 `+.`。

## 2. 瘦身方案（本机已部署）

### 做法

只在 OpenClash **生成运行配置的最后一步** 用官方钩子改写配置，源订阅文件也能保持干净：

```
订阅源 /etc/openclash/config/zhu5in1.yaml        （84 KB，UI 里看到的就是这份，已瘦身）
        │
        ├─ yml_change.sh → yml_rules_change.sh    （OpenClash 注入 dns/sniffer/端口等）
        │
        ├─ /etc/openclash/custom/openclash_custom_overwrite.sh
        │     ├─ [既有] OPENCLAW_STEAM_GAME_PROXY   Steam 规则前置（严格模式下会被丢弃）
        │     └─ [新增] OPENCLAW_MRS_SLIM → oc-mrs-slim.sh → oc_mrs_slim.rb
        │            · 写入 13 个 rule-providers（guize .mrs）
        │            · 删除内联 DOMAIN / DOMAIN-SUFFIX / IP-CIDR / IP-CIDR6（目标组属于这 7 类）
        │            · 严格模式：连 DOMAIN-KEYWORD / PROCESS-NAME / GEOIP 一起丢掉
        │            · 插入 13 条 RULE-SET，保持分流优先级
        │            · 缺“开发平台”策略组就自动从“国外媒体”复制一个
        │            · 同一个脚本再对「订阅源」跑一遍，保证 UI 里那份也是瘦的
        │
        └─ /etc/openclash/zhu5in1.yaml   （89 KB，真正给内核用，rules 只有 14 条）
```

### rules 里为什么原来还有“散规则”

`.mrs` 只能装 `DOMAIN` / `DOMAIN-SUFFIX` / `IP-CIDR`，**装不下** `DOMAIN-KEYWORD`、`PROCESS-NAME`、`GEOIP`、`MATCH`。
原始配置里这类规则有 108 条，所以第一版瘦身后 `rules:` 还剩 122 条：

| 类型 | 条数 | 说明 |
|---|---:|---|
| `DOMAIN-KEYWORD` | 93 | `google`/`facebook`/`paypal`/`alicdn`/`bilibili`… 关键字匹配，`behavior: domain` 规则集表达不了 |
| `PROCESS-NAME` | 14 | `com.netflix.mediaclient` 等。路由器看不到客户端进程名，本来就是无效规则 |
| `GEOIP,CN` | 1 | 传统 GeoIP 规则，已被 `direct-ipcidr.mrs`（7663 条 CN CIDR）取代 |
| Steam 自定义 | 12 | 之前会话加的 `DOMAIN-SUFFIX,steampowered.com,♻️ 亚洲自动` 等 |
| `MATCH` | 1 | 兜底，必须留 |

**现在已开「严格模式」，`rules:` 里只剩 13 条 RULE-SET + `MATCH` 兜底 = 14 条。**

丢掉的规则不会造成覆盖缺口（已逐条核对关键字对应的域名落在哪个 mrs）：

| 关键字 | 域名落在哪 | 关键字 | 域名落在哪 |
|---|---|---|---|
| alicdn / alipay / 360buy / jdpay / qhimg / xiaomi / bilibili / baidupcs | 🎯 直连 `direct-domain.mrs`（3~15 条命中） | paypal | 🎥 媒体 `foreign-media-domain.mrs`（159 条） |
| google / amazon / facebook / twitter / youtube / netflix / spotify / tiktok / whatsapp / telegram | 对应分类 mrs（10~291 条命中） | onedrive / dropbox / pinterest / adobe / github / steam | 苹果 / 媒体 / 拦截 / 开发 / 直连 的 mrs |

一句话开关（在 `openclash_custom_overwrite.sh` 的 `OPENCLAW_MRS_SLIM` 段）：

```sh
OC_MRS_STRICT=1   # 默认：rules 只留 13 条 RULE-SET + MATCH
OC_MRS_STRICT=0   # 回退：保留关键字/进程/GEOIP 规则，Steam 继续走亚洲自动
```

### 两个 yaml 别搞混（这就是“看起来没瘦身”的原因）

| 文件 | 谁在用 | 之前 | 现在 |
|---|---|---:|---:|
| `/etc/openclash/zhu5in1.yaml` | **内核真正加载的**（`clash -d /etc/openclash -f`） | 2 811 872 B | **89 032 B** |
| `/etc/openclash/config/zhu5in1.yaml` | OpenClash UI「配置文件」里显示/订阅源 | 2 528 101 B | **84 248 B** |
| `/etc/openclash/config/zhu111.yaml` | UI 里的另一个遗留配置 | 2 506 304 B | **63 031 B** |
| `/etc/openclash/zhu111.yaml` | zhu111 的遗留运行配置 | 2 790 617 B | **67 717 B** |

一开始只瘦了「运行配置」，所以 UI 里看到的订阅源仍旧是 2.4 MB。
现在**两个都瘦**（`zhu111` 也一起瘦了），并且钩子每次生成配置时会同时处理这两份，
以后点“更新订阅”拿回胖文件也会自动再瘦一次。
原始大文件全部备份在 `/etc/openclash/config-backup/`，overlay 顺带省下约 7.3 MB。

### 效果（实测）

| 指标 | 之前 | 之后 |
|---|---:|---:|
| 内联 rules（运行配置） | 47 111 条 | **14 条**（13 RULE-SET + MATCH） |
| 规则总数 | 47 111 | 13 个规则集 ≈ 48 218 条 |
| 内核 RSS（同配置 A/B 实测） | 77.6 MB | 62.7 MB |

> A/B 方法：用同一份运行配置（同样的 dns/策略组/节点），只把 `rules:` 在「47 105 条内联」和
> 「13 条 RULE-SET + mrs」之间切换，分别启动内核读取 `/proc/<pid>/status` 的 `VmRSS`。
> 两组都带 OpenClash 自己的 `oc-cn-domain`（11 万条）规则集，所以差值就是内联规则 vs mrs 的差距。

启动日志：
```
Start Running MRS Ruleset Slim Script...
[oc-mrs-slim] rules: 47111 -> 134（删除内联 46990，新增 RULE-SET 13）
[oc-mrs-slim] rule-providers: 13 个 mrs（其余内置 provider 保留）
[oc-mrs-slim] 分流顺序: 🤖 AI平台 -> 🛑 全球拦截 -> 📲 社交聊天 -> 💻 开发平台 -> Ⓜ️ 微软苹果 -> 🎥 国外媒体 -> 🎯 全球直连
```

分流顺序和原配置一致，只在「社交聊天」后插入新的「💻 开发平台」。
`GEOIP,CN`、`DOMAIN-KEYWORD`、`PROCESS-NAME`、`MATCH` 等 mrs 装不下的规则原样保留。

## 3. 文件清单（路由器）

| 路径 | 作用 |
|---|---|
| `/etc/openclash/custom/oc_mrs_slim.rb` | 瘦身主程序（ruby + psych，幂等） |
| `/etc/openclash/custom/oc-mrs-slim.sh` | 包装脚本，可手动对任意配置执行 |
| `/etc/openclash/custom/oc-mrs-fetch.sh` | 预下载/刷新 13 个 .mrs 到 `rule_provider/` |
| `/etc/openclash/custom/oc-patch-yamlrb.sh` | 让 OpenClash 自己生成的配置也用 UTF-8 写 emoji（幂等，升级后重跑即可） |
| `/etc/openclash/custom/openclash_custom_overwrite.sh` | OpenClash 钩子，已追加 `OPENCLAW_MRS_SLIM` 段（同时瘦运行配置和订阅源） |
| `/etc/openclash/rule_provider/*.mrs` | 13 个 guize 规则集（预置缓存，保证离线可启动） |
| `/etc/openclash/config-backup/*.fat.*.yaml` | 瘦身前的原始大文件备份 |

备份：`openclash_custom_overwrite.sh.bak.<时间戳>`。

## 4. 常用操作

```sh
# 看瘦身结果
grep oc-mrs-slim /tmp/openclash.log

# 手动对当前配置瘦身（幂等）
/etc/openclash/custom/oc-mrs-slim.sh

# 严格模式：rules 只留 13 条 RULE-SET + MATCH
/etc/openclash/custom/oc-mrs-slim.sh /etc/openclash/config/zhu5in1.yaml --strict

# 只预览不写回
/etc/openclash/custom/oc-mrs-slim.sh /etc/openclash/zhu5in1.yaml --dry-run --strict

# 刷新 .mrs 缓存
/etc/openclash/custom/oc-mrs-fetch.sh

# 让内核立即重新拉取某个规则集
curl -H "Authorization: Bearer $SECRET" -X PUT http://127.0.0.1:9090/providers/rules/ai-platform-domain

# 看规则集加载情况（名称/behavior/规则数）
curl -s -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/providers/rules | jq .

# 订阅更新后：OpenClash 重启时会自动重新瘦身；也可在 UI 里点一下“配置文件重载”
/etc/init.d/openclash restart
```

`$SECRET` = `uci get openclash.config.dashboard_password`。

## 5. 验证记录

```
$ mihomo -t -d /etc/openclash -f /tmp/oc-mrs-test.yaml
configuration file /tmp/oc-mrs-test.yaml test is successful

$ curl -s -H "Authorization: Bearer ..." http://127.0.0.1:9090/providers/rules
ai-platform-domain      Domain   84      HTTP
ai-platform-ipcidr      IPCIDR   2       HTTP
developer-platform-domain Domain 133     HTTP
developer-platform-ipcidr IPCIDR 22      HTTP
direct-domain           Domain   2247    HTTP
direct-ipcidr           IPCIDR   7663    HTTP
foreign-media-domain    Domain   34124   HTTP
foreign-media-ipcidr    IPCIDR   1243    HTTP
microsoft-apple-domain  Domain   2236    HTTP
microsoft-apple-ipcidr  IPCIDR   13      HTTP
oc-cn-domain            Domain   111021  HTTP   ← OpenClash 自带的 fake-ip-filter 规则集，保留
reject-domain           Domain   159     HTTP
social-chat-domain      Domain   813     HTTP
social-chat-ipcidr      IPCIDR   80      HTTP

$ 实测分流（严格模式，经 172.18.18.2:7890 代理）
www.taobao.com   -> RuleSet(direct-domain)          🎯 全球直连 -> DIRECT
www.baidu.com    -> RuleSet(direct-domain)          🎯 全球直连 -> DIRECT
www.bilibili.com -> RuleSet(direct-domain)          🎯 全球直连 -> DIRECT
www.netflix.com  -> RuleSet(foreign-media-domain)   🎥 国外媒体 -> 302
www.paypal.com   -> RuleSet(foreign-media-domain)   🎥 国外媒体 -> 302   ← 原 DOMAIN-KEYWORD,paypal
www.dropbox.com  -> RuleSet(foreign-media-domain)   🎥 国外媒体 -> 200
www.apple.com    -> RuleSet(microsoft-apple-domain) Ⓜ️ 微软苹果 -> 200
github.com       -> RuleSet(developer-platform-domain) 💻 开发平台 -> 200  ← 原 DOMAIN-KEYWORD,github
chatgpt.com      -> RuleSet(ai-platform-domain)     🤖 AI平台 -> 403(CF)
www.adobe.com    -> RuleSet(reject-domain)          🛑 全球拦截 -> REJECT
raw.githubusercontent.com -> RuleSet(developer-platform-domain) 💻 开发平台
（CN IP 仍走直连：direct-ipcidr.mrs 命中 192 次，顶替原来的 GEOIP,CN）
```

> 测试中偶发 `000` 是节点池里挑到了死节点
> （`c.normal.main.sys-metric-report.com:9060 i/o timeout`），
> 触发一次 `GET /group/<组名>/delay` 让健康检查切走即恢复，与规则无关。

### 域名匹配语义实测（用同版本内核单独跑对照组）

```
payload "example.org"   -> example.org 命中 REJECT；www.example.org 不命中
payload ".example.net"  -> www.example.net 命中 REJECT；example.net 不命中   ← 原仓库的写法
payload "+.example.com" -> example.com 与 www.example.com 都命中            ← 修复后的写法
```

### 修复前后对比（顶级域名）

| 域名 | 修复前 | 修复后 |
|---|---|---|
| `openai.com` / `chatgpt.com` / `anthropic.com` / `claude.ai` | `MATCH` → 🐟 漏网之鱼 | `RuleSet(ai-platform-domain)` → 🤖 AI平台 |

修复提交：`aoxijy/guize@f3254a7`（`scripts/update_mrs.py` + `Clash/MRS/README.md`），
GitHub Actions `Update Mihomo MRS rulesets` 已成功重编译并覆盖 `mrs-latest` Release；
路由器侧用 `PUT /providers/rules/<name>` 热更新了 13 个规则集，**无需重启内核**。

## 6. 为什么会有 `\U0001F916` 这种写法（微软苹果那行为什么不一样）

同一个文件里出现

```yaml
- "RULE-SET,ai-platform-domain,\U0001F916 AI平台"     # 4 字节 emoji 被转义
- RULE-SET,microsoft-apple-domain,Ⓜ️ 微软苹果          # 3 字节字符原样输出
```

**不是配置写错了，是 Ruby 的 YAML 序列化规则**：libyaml 只把 UTF-8 前导字节在
`0xC2~0xEF`（即 U+FFFF 以下，3 字节）的字符当成"可打印"，原样输出；
`U+10000` 以上的（4 字节，前导字节 `0xF0`，也就是 🤖🎥📲🎯🛑🐟）算"不可打印"，
于是被写成 `\U0001F916` 转义。两种写法 YAML 解析出来是**同一个字符串**（已用 `==` 验证）：

```
文件中 AI平台 规则原文 : RULE-SET,ai-platform-domain,🤖 AI平台
== 期望字符串?        : true
策略组里确实有 🤖 AI平台   : true
策略组里确实有 Ⓜ️ 微软苹果: true
```

已经彻底统一：

1. `oc_mrs_slim.rb` dump 时把 4 字节 emoji 还原成 UTF-8（源配置/UI 里看到的那份）
2. `oc-patch-yamlrb.sh` 给 `/usr/share/openclash/YAML.rb` 的 dump 加同样的后处理，
   OpenClash 自己最后回写运行配置时也不会再转义（运行配置那份）

现在两份文件的 `rules:` 都是统一的 UTF-8 写法，`grep -c '\\U0001F'` 为 0。

## 7. 断网会不会失效？（结论：不会，已经实测）

`rule-providers` 用的是 `type: http`，但 mihomo 启动时**先读 `path` 指向的本地文件**，
只有文件不存在时才必须联网。也就是说：

| 场景 | 结果 |
|---|---|
| 有本地缓存 + 联网正常 | 正常启动；后台按 `interval` 自动更新 .mrs |
| 有本地缓存 + **完全断网 / GitHub 被墙** | **正常启动、正常分流**；只在日志里留一行 `[Provider] xxx pull error` |
| 没有缓存 + 断网 | 启动失败（这是唯一会出问题的情况） |
| 没有缓存 + 联网正常 | 自动下载后正常启动（自愈） |

### 实测（把 14 个规则集的 url 全改成不可达域名 + 缓存文件时间改成 10 天前）

```
providers: 14 个（url 全部改成不可达）
--- 进程 ---           内核存活 pid=29826
--- 规则集加载情况 ---  ai-platform-domain 84 | foreign-media-domain 34124 | direct-ipcidr 7663 | ... 全部有数（读的是本地缓存）
--- 分流 ---           codeload.github.com -> RuleSet(developer-platform-domain) 💻 开发平台
--- 报错（确实尝试联网但失败，不影响运行）---
level=error msg="[Provider] social-chat-ipcidr pull error: Get "https://offline-test.invalid/social-chat-ipcidr.mrs": EOF"
```

### 三重保险

1. **本地缓存**：`/etc/openclash/rule_provider/*.mrs`（overlay 持久化，OpenClash 不会删它）
2. **本地备份 + 自动恢复**：`/etc/openclash/custom/mrs-backup/`（14 个，851 KB）
   - `oc-mrs-restore.sh` 缺什么补什么，全程不联网
   - 已接进 OpenClash 启动钩子：每次生成配置前自动补齐
   - 已装兜底 cron：每 10 分钟检查一次（`#oc-mrs-selfheal`）
3. **迁移离线包**：NAS `/www/wwwroot/openclash-mrs/openclash-mrs-bundle.tar.gz`（853 KB）
   换机器时 `cd / && tar xzf ...` 就能把脚本 + 14 个 .mrs 一次铺好，**全程不需要网络**

```sh
# 检查缓存是否齐全
/etc/openclash/custom/oc-mrs-restore.sh --check

# 万一被删了，从本地备份恢复
/etc/openclash/custom/oc-mrs-restore.sh

# 把当前缓存重新备份一份（比如 mihomo 刚联网更新过）
/etc/openclash/custom/oc-mrs-restore.sh --backup

# 联网时手动刷新到最新（可选，平时 mihomo 自己会刷）
/etc/openclash/custom/oc-mrs-fetch.sh
```

如果哪天想彻底摆脱"缓存文件"这个概念，也可以把配置里的 `type: http` 改成
`type: file`（删掉 url/interval），效果一样但永远不会尝试联网 —— 代价是丢掉了自动更新。
目前保持 `type: http` + 本地缓存，是"离线可用"和"自动更新"两者兼得。

## 8. 全新的 OpenWrt、一开始没外网，能用吗？

**配置文件本身没问题**（规则集、节点、策略组都在文件/离线包里），但要注意：
全新系统上 OpenClash **自己会去网上下载 3 样东西**，没外网就会卡住 —— 这跟配置文件无关。

| 新系统缺什么 | OpenClash 的行为 | 解法 |
|---|---|---|
| **mihomo 内核** `/etc/openclash/core/clash_meta` | `[ ! -f "$CLASH" ]` → `openclash_core.sh` 下载 → 失败就 `start_fail` | 必须预置（离线包里有，13 MB） |
| **chnroute 列表** `china_ip_route.ipset` / `china_ip6_route.ipset` | `china_ip_route=1` 时若文件不存在 → `openclash_chnroute.sh` 下载 | 必须预置（离线包里有，133 KB） |
| **OpenClash 本体 + 依赖** | 靠 opkg/apk 安装 | 用带 OpenClash 的固件，或提前下好同架构 ipk 离线安装 |
| GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb（共 47 MB） | 启动时**不会**下载；只有用到 GEOIP/GEOSITE 规则才读 | **不需要**——严格模式配置里已无任何 geo 规则，实测把这 4 个文件删掉 `mihomo -t` 依然 successful，省 47 MB |
| 14 个 `.mrs` 规则集 | 文件不存在时才联网下载 | 离线包里有，`oc-mrs-restore.sh` 也能从本地备份恢复 |

### 一键离线部署包

NAS：`/www/wwwroot/openclash-mrs/openclash-fresh-kit-x86_64.tar.gz`（15 MB，x86_64）

```
tar xzf openclash-fresh-kit-x86_64.tar.gz && cd <解包目录> && sh install-offline.sh
```

脚本干这些事：放内核并建 `clash` 软链 → 铺 14 个 .mrs + chnroute + 脚本 → 放你的配置文件 →
写入 uci（`config_path` 指向该配置、`enable=1`）→ 装兜底 cron + 打 YAML.rb 补丁 →
`/etc/init.d/openclash restart` → 检查内核是否起来。**全程不需要网络。**

已在现网端到端跑过一遍（内容与线上一致，等于幂等回归）：

```
=========== 0. 环境检查 ===========     OpenWrt: 24.10.5 x86_64 / ruby 3.3.6 ✓
=========== 1. 内核 ===========         Mihomo Meta alpha-ge183c58 linux amd64
=========== 2. 规则集 ===========       规则集: 14 个 / 本地备份: 14 个
=========== 4. uci ===========          config_path = /etc/openclash/config/zhu5in1.yaml
=========== 5. 自检 ===========         备份齐全 / cron 已存在 / 补丁已打 / 配置已是 mrs 版
=========== 6. 启动 ===========         内核已运行 ✓
```

> 换到别的架构（aarch64 等）的话，把该架构的 `clash_meta` 换进 `etc/openclash/core/` 即可，
> 其余内容通用。OpenClash 本体建议直接用带 OpenClash 的固件，或者提前用同架构 ipk 离线装。

---

## 9. 在固件仓库里是怎么落地的（aoxi-openwrt）

刷完机**不需要任何手动操作**，首次开机会自动做完：

| # | 做什么 | 脚本 |
|---|---|---|
| 1 | 给 OpenClash 的 `YAML.rb` 打补丁：emoji 用 UTF-8 写，不再变成 `\U0001F916` | `oc-patch-yamlrb.sh` |
| 2 | 从本地备份补齐 14 个 `.mrs` 规则集（不联网）+ 装兜底自愈 cron | `oc-mrs-restore.sh` |
| 3 | 固件不预置节点配置；没有配置时从 U 盘 / 局域网自动导入 | `oc-mrs-import.sh` |
| 4 | 规则严格模式瘦身（rules 只留 13 条 RULE-SET + MATCH） | `oc-mrs-slim.sh` |
| 5 | 装 LuCI 的 MRS 延迟面板入口（首页卡片 + 设置页项） | `oc-luci-panel.rb` |
| 6 | 把被接管的策略组改成 `select`，并装选路模型的定时任务 | `oc-smart.rb convert` / `oc-smart.sh --install-cron` |
| 7 | 生成设备专属密钥并填进面板 | `oc-panel-secret.sh` |

之后 **每次 OpenClash 生成运行配置**，钩子 `openclash_custom_overwrite.sh` 都会再走一遍
「补 `.mrs` → 瘦身 → 重打 LuCI 补丁 → 对齐 `select` → 密钥自愈」——
所以换订阅、改配置、甚至升级 OpenClash 之后，这些都会自动恢复，不用管。

### 编译前自检（失败会直接阻断编译）

`tests/run_all.sh`：

| 检查 | 防的是什么 |
|---|---|
| `test_no_credentials.py` | 公开镜像里出现固定密钥（真出过事，见第 10 节） |
| `test_luci_panel_patch.py` | OpenClash 升级后 LuCI 补丁锚点失配、面板入口静默消失 |
| `test_panel_secret.sh` | 面板密钥生成/注入逻辑坏掉 |
| `test_jbox_targets.py` | J-Box 变体混进 OpenClash；`aoxi-package` 没锁提交 |

---

## 10. 凭据：镜像里一个都不带

固件仓库和 Releases 都是**公开**的，所以 `etc/config/openclash` 里这两项**留空**：

| 项 | 作用 | 留空后怎么办 |
|---|---|---|
| `config.dashboard_password` | mihomo 的 `secret`，调 `http://<路由>:9090` 的 Bearer 密钥 | 首启由 `oc-panel-secret.sh` 生成 12 位随机串 |
| `@authentication[0].password` | SOCKS5/HTTP(S) 代理认证密码（该项启用时） | 同上，仅在「已启用且为空」时补随机值 |

生成后脚本会把密钥**写进 MRS 面板**（替换 `index.html` 里的 `__MRS_SECRET__` 占位符），
所以打开面板就能用，不用手抄；你在 OpenClash 设置里改了密码，钩子下次会同步过去。

> 为什么要这么做：第一版把路由器上的 `etc/config/openclash` 直接搬进了仓库，
> 结果 API 密钥和代理认证密码都写在了 GitHub 上，**所有刷这个固件的设备共用一份公开密钥**。
> 现在每台设备各自随机，镜像里查不到任何凭据。

怎么查看/修改：

```sh
uci get openclash.config.dashboard_password          # 当前 API 密钥
uci get openclash.@authentication[0].password        # 当前代理认证密码
# 改（改完下次启动自动同步到面板）
uci set openclash.config.dashboard_password='你自己设一个'; uci commit openclash
/etc/openclash/custom/oc-panel-secret.sh --inject-only   # 立即同步到面板
```

---

## 11. 选路模型（Smart 优选节点）

被接管的组会在每个组**自己的成员里**挑最优（绝不跨组），每节点保留最近 10 条测速记录，
按「延迟 + 抖动 + 超时」打分，当前节点不明显更差就不动。

| 定时任务 | 频率 | 干什么 |
|---|---|---|
| `oc-smart.sh cycle` | 每 5 分钟 | 全量测速一轮（约 3 分钟；同服务器串行、不同服务器并发 8） |
| `oc-smart.sh guard` | 每 1 分钟 | 只测每个组**当前选中**的节点，连续两次不通立刻换（不用等整轮） |
| `oc-smart.sh watchdog` | 每 10 分钟 | 模型超过 30 分钟没更新状态 → 把组交回内核 `url-test` 自管（安全兜底） |

常用命令：

```sh
oc-smart.sh status            # 每个组的当前节点 / 得分 / 候选前三
oc-smart.sh select --force    # 立刻按已有记录重选（忽略"手动让位"）
oc-smart.sh guard             # 手动跑一次快速守护
oc-smart.sh type              # 看被接管的组现在是什么类型
oc-smart.sh revert            # 全部交回内核 url-test
oc-smart.sh reset             # 清空测速记录
oc-smart.sh --remove-cron     # 卸载全部定时任务
```

调参在 `/etc/openclash/custom/oc-smart.conf`（每节点记录数、周期、超时、抖动容忍、
手动让位时间、接管哪些组、各组的专用测试 URL 等）。

---

## 12. 为什么锁死 `aoxi-package` 的提交

`build/<变体>/custom.sh` 里：

```sh
AOXI_PACKAGE_COMMIT="2121c2393259492e8c4f360775a2c3bc9fdd4370"
```

`aoxi-package` 会被上游机器人**自动同步**（OpenClash 本体随之更新），而 LuCI 面板补丁是靠
字符串锚点改 OpenClash 自带 Lua 文件的 —— 锚点一变，补丁就会在刷机后静默失败
（症状：LuCI 里根本没有 MRS 面板入口）。所以：

1. 固定到已实测通过的提交，保证固件可复现；
2. 升级时改 SHA，然后**先本地跑** `python3 tests/test_luci_panel_patch.py`
   确认三处锚点仍匹配（用真实源码片段预演），再提交编译。

---

## 13. 刷完机怎么确认生效

```sh
# 1) 规则集是不是 14 个、规则是不是只剩 13 条 RULE-SET + MATCH
ls /etc/openclash/rule_provider/ | wc -l
grep -c '^  - RULE-SET' /etc/openclash/zhu5in1.yaml

# 2) 收管的组是不是 select、模型有没有在跑
/etc/openclash/custom/oc-smart.sh type
/etc/openclash/custom/oc-smart.sh status
tail -5 /etc/openclash/smart/status.txt

# 3) 面板密钥有没有生成、有没有填进面板
uci get openclash.config.dashboard_password
grep -c "__MRS_SECRET__" /usr/share/openclash/ui/mrs-panel/index.html   # 应为 0

# 4) LuCI 入口是否装上（应全是 ✓）
ruby /etc/openclash/custom/oc-luci-panel.rb status
```

浏览器：

| 入口 | 地址 |
|---|---|
| MRS 延迟面板（每节点最近 10 次记录，鼠标悬停延迟条看详情） | `http://<路由IP>:9090/ui/mrs-panel/` |
| OpenClash 控制面板首页（有 MRS 面板卡片） | `http://<路由IP>/cgi-bin/luci/admin/services/openclash/client` |
| 覆写设置 → Dashboard（可把 MRS Panel 设为默认面板） | `http://<路由IP>/cgi-bin/luci/admin/services/openclash/settings` |

