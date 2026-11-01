# 双旁路由 VRRP（手动启用）

四种固件均内置 Keepalived、flock、libcap-bin、ip-full、kmod-tun 及快速配置脚本。
首次启动只创建 `/tmp/ha-quick`，不自动开启 VRRP，不改默认 LAN IP 或代理配置。

先将设备 LAN 设置为 172.18.18.2 或 172.18.18.8/24，接口 br-lan，默认网关
172.18.18.1，关闭本机 DHCP，并配置、启动对应的代理订阅及本地 DNS。
然后从 SSH 终端选择一条命令：

| 设备 | J-box | OpenClash |
|---|---|---|
| 主用 .2 | `sh /tmp/ha-quick/install.sh 2 jbox` | `sh /tmp/ha-quick/install.sh 2 openclash` |
| 备用 .8 | `sh /tmp/ha-quick/install.sh 8 jbox` | `sh /tmp/ha-quick/install.sh 8 openclash` |

也可使用 `ha-quick 8 openclash`；末尾加 `--check` 只做环境预检。
没有匹配的代理服务或尚未启动时，安装器会拒绝继续。

## 密钥留在设备本地

公开源码及公开固件不包含真实 EasyTier 网络密钥或 NPC vkey。
安装器优先使用 `/etc/ha-quick/identity.conf`，其次读取设备现有 EasyTier/NPC 配置；
否则在交互终端隐藏输入两项密钥。NPC 必须使用两台共用的**原主身份密钥**，
而非备用客户端的另一个密钥，才能接管原公网端口。

无人值守部署前，在设备上用编辑器创建该文件并 `chmod 600`：

```sh
HA_ET_SECRET='填写组网密钥'
HA_NPS_VKEY='填写两台共用的主密钥'
```

当前身份格式支持字母、数字、下划线、连字符；特殊字符密钥需先适配解析器。
请勿把填好的文件提交到此公开仓库。安装器会将其登记到 sysupgrade.conf；
完全清空配置重装后须重新输入，保留配置升级时通常可继续使用。

## 固定拓扑与行为

- VIP 172.18.18.18/24；两台自己的默认网关保持 .1。
- .2 优先级 150、EasyTier 172.18.28.180；.8 优先级 100、EasyTier .181。
- 独立 UUID、网络 yksnet，发布 172.18.18.0/24；三个原 TCP peer 保持不变。
- VRRP v3 单播、VRID 218、不抢占，仅 VIP 持有者运行 EasyTier/NPC。
- J-box 或 OpenClash/DNS 常驻；只检查本地就绪，切换后连接重新建立。
- 主路由 DHCP 网关及 DNS 应为 .18；NPS 18014 对应目标 .18:80。
- J-box 模式恢复 EasyTier 专用 GID 20260/mark 0x2024 绕过，要求兼容的
  `jbox_apply_dns_mark` 钩子；未知插件格式会拒绝安装，不会整包覆盖插件。
- 首次网络重载可能清除 EasyTier TUN 地址，协调脚本会补恢复。

每次安装前备份至 `/root/ha-restore-时间/before.tgz`。等待约 20 秒后执行
`ha-status`：两台 health_exit=0，只有一台持有 VIP、运行 EasyTier/NPC。
一次只重装一台。已就绪节点不会抢回当前主角色，手动回切前先检查另一台健康。
脚本不覆盖整份 network/firewall，也不转换或同步两种代理的订阅和规则。
跨固件恢复请只恢复所需配置，勿将旧 /etc/config 整体覆盖到不同固件。
