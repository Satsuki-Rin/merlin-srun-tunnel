# 运行与配置

一个常驻 Shell 控制器完成深澜认证、Xray 生命周期、双栈策略路由和 DNS。运行逻辑只有 `netctl.sh` 与 `xencode.awk` 两个源码文件；所有用户参数放在 `net-stack.conf`。`install.sh` 只在安装/升级时执行，不是另一个守护。

组网用途是把校园侧 LAN 通过家庭端点接入家庭网络。访问家庭内网资源、查询家庭 DNS 和使用家庭互联网出口都依赖家庭侧 Xray 的转发规则及网络可达性；家庭网段应与校园侧 LAN、TUN 网段互不重叠。

[返回首页](../README.md) · [测试说明](TESTING.md) · [Xray 构建](XRAY.md)

## 文件与状态

实际安装目录固定为 `/jffs/scripts/net-stack`：两个运行源码文件、`net-stack.conf`、`mode`、独立的 `bin/xray` 和说明文档。固件要求的五个 hook 各追加一条调用，不复制控制逻辑。持久存储只在安装、改配置或切换模式时写入；PID、内核锁、登录限频、DNS 缓存、生成的 Xray JSON、状态与日志都在 `/tmp/net-stack`。

`net-stack.conf` 含校园密码与代理 UUID，权限必须是 600，目录权限 700。工作站上的真实配置建议保存在 `~/.config/merlin-srun-tunnel/net-stack.conf`。Git 忽略规则覆盖配置、日志、二进制和打包产物；忽略规则无法清除已经提交的历史内容。

## 配置参考

配置由 Shell 直接载入，不是 JSON 或 INI。只使用可信配置；字符串含空格或特殊字符时使用 Shell 引号。密码含单引号时可在安装后使用 `netctl.sh password` 交互更新。

| 配置项 | 用途与约束 |
| --- | --- |
| `LAN_IF`、`WAN_IF`、`WAN_UNIT` | LAN 桥、实际 WAN 出口及 NVRAM WAN 单元；与设备当前路由和接口核对 |
| `LAN_CIDR` | LAN IPv4 网段；不能与家庭网段或 TUN 网段重叠 |
| `LAN6_CIDR`、`LAN6_ADDR` | LAN ULA 网段和路由器地址；SLAAC 必须使用 `/64` |
| `TABLE`、`RULE_PRIORITY` | 独立策略表及规则优先级；默认 300、12000，需避免固件/插件占用，表号至少 300 |
| `TUN`、`TUN4`、`TUN6`、`MTU` | TUN 名称、地址和 MTU；默认 `xray0`、1400 字节 MTU |
| `PORTAL_IP`、`PORTAL_PORT`、`AC_ID` | 深澜门户 IPv4、HTTP 端口和接入控制器标识；从实际门户确认 |
| `USERNAME`、`PASSWORD`、`DOUBLE_STACK` | 校园账号、密码和门户双栈参数；`DOUBLE_STACK` 按门户要求设为 0 或 1 |
| `ENDPOINT`、`ENDPOINT_PORT` | 家庭端点域名及 TLS 端口；保留域名，认证预访问要求有可用 A 记录 |
| `UUID`、`TLS_NAME` | VLESS 用户 UUID 和 TLS SNI；模板的全零 UUID 会被拒绝 |
| `XHTTP_HOST`、`XHTTP_PATH` | 与服务端一致的 XHTTP Host 和路径；当前生成器固定为 stream-one |
| `HOME_DNS` | 经隧道可达的家庭 DNS 地址 |
| `DNS1`、`DNS2` | 引导 DNS 的 IPv4 地址，仅用于解析家庭端点 |
| `SOCKS_PORT`、`DNS_PORT` | 本机 SOCKS 和 DNS 转发端口；默认 1080、15353，避免与插件冲突 |
| `HEALTH_URL`、`HEALTH_STATUS` | 主探测 HTTPS URL 和精确预期状态码；模板为 `https://$ENDPOINT:$ENDPOINT_PORT/`、200，访问家庭端点 fallback |
| `HEALTH_DNS_SERVERS` | 主探测失败后的 DNS 复核列表；默认模板为 `119.29.29.29 223.5.5.5`，按顺序经 SOCKS 查询 TCP/53，任一个有效应答即成功；设空可禁用 |
| `HEALTH_FALLBACK_URL`、`HEALTH_FALLBACK_STATUS` | 可选的额外 HTTPS 复核，排在 DNS 之后；模板 URL 为空，不依赖境外探测站；保留旧配置兼容 |
| `AUTH_INTERVAL`、`LOGIN_INTERVAL` | 门户检查与最小登录间隔；默认 30、60 秒，分别不得低于 15、20 秒 |
| `HEALTH_INTERVAL`、`DNS_INTERVAL` | 隧道健康和端点 DNS 检查间隔；默认 15、60 秒，健康间隔至少 5 秒 |
| `HTTP_TIMEOUT`、`BOOT_DELAY` | 单次 HTTP 超时及首次稳定等待；默认 8、20 秒，HTTP 超时须在 1–30 秒 |

配置检查只能验证脚本已覆盖的语法和约束，不会证明接口、门户或服务端参数正确。字段模板以根目录 `net-stack.conf.example` 为准。

## 三种模式

| 命令 | 行为 |
|---|---|
| `netctl.sh mode tunnel` | 自动认证；LAN IPv4/IPv6 仅经 TUN；异常时封锁 |
| `netctl.sh mode auth` | 自动认证；停止 Xray，恢复固件普通转发和 DNS |
| `netctl.sh mode off` | 不发起认证，停止 Xray，恢复固件普通转发和 DNS |

模式持久化，重启后保留。`off` 不等于门户注销：已有校园会话可继续在线，需要注销时单独执行 `logout`。`auth/off` 的原生 IPv6 能力取决于固件及校园网分配，不提供隧道的 ULA 到家庭 IPv6 转发。

三个模式都保留一个轻量控制进程和同一条 cron，避免切回 tunnel 后漏装巡检。切换命令先同步安装保护/撤销本项目规则，然后唤醒控制器；认证、DNS 服务重启与健康确认是异步的，请用 `status` 判断完成，不能把命令退出当成联网成功。

## 控制流程

```text
init-start ──► 尽早安装保护
services-start / cron / mode ──► 确保同一个控制器运行
WAN / firewall hook ──► 同步安装保护 + 请求重新检查
                                  │
                       唯一控制器，每 2 秒推进一次
                                  │
       读取模式 → WAN IP/路由 → 校时 → 门户状态 → 必要时认证
                                  │
                DDNS → Xray → 健康检查 → 双栈路由与放行
```

控制器持有内核 `flock` 单实例锁。校时不会让锁过期，进程退出后内核自动释放。WAN 事件只提供“重新检查”的提示，既不重启认证守护，也不把乱序 `stopped/connected` 写成永久暂停标记。即使恢复事件丢失，下轮也会根据 WAN 路由与门户响应重新判断。

网络请求都在防火墙更新锁之外，且有超时；每轮执行有限步骤。控制器的单实例锁在整个进程生命周期内持有，防火墙使用另一个短锁。登录只有一个调用者，手动请求和 WAN 事件共用限频与重试状态。

首次启动默认等待 20 秒稳定期，期间 LAN 已受保护。门户查询区分在线、明确离线、未知；HTTP 失败、字段缺失或在线 IP 不匹配都属于未知，不触发登录。确认离线后，先访问家庭端点的 HTTP/80，让接入设备建立认证重定向上下文，再获取 challenge、提交登录，最后最多查询三次确认真实在线。`error=ok` 本身不作为认证完成的依据。

登录提交间隔默认至少 60 秒，所有 `login`、事件和控制器重启共用 `/proc/uptime` 时间戳。可调大；脚本拒绝小于 20 秒的配置。状态检查默认 30 秒、隧道健康检查 15 秒、DDNS 检查 60 秒。WAN 事件可提前检查状态，但不能跳过登录限频。不使用旧版的 10/20/30 秒多条快速通道。

Xray 由控制器直接启动和回收。意外退出后的重启延迟从 2 秒递增，上限 300 秒；存活但连续两次健康检查失败也会停止重启，首次等待至少 20 秒，避免持续冲击家庭端点。健康恢复后重置退避。实际恢复还包含进程装载、DNS 和 TLS 耗时，不承诺“一秒内恢复”。控制器被强杀时，cron 最迟约一分钟重新拉起它。

健康检查先确认 Xray 身份、TUN 和本机 DNS 监听，再经本地 SOCKS 发起完整 HTTPS GET。默认主探测为自己的 nginx fallback，要求 curl 成功且返回配置的 200；失败后按顺序向两个国内公共 DNS 复核，任一个有效应答即成功。已放行隧道首轮全部网络探测失败时记为 `tunnel-degraded`，仍只允许经 TUN 转发；连续两轮失败才封锁并重启，成功即清零计数。冷启动、已有封锁、Xray/TUN/DNS 监听缺失仍立即保持或进入封锁，不会借容错提前放行或允许 WAN 直连。每个目标最多 `HTTP_TIMEOUT` 秒，模板最多三个目标，下一轮从本轮结束后计时。HTTPS 禁用 curlrc 和重试，不跟随重定向、不跳过证书验证，`NO_PROXY` 也不能使请求绕过 SOCKS。

DNS 复核使用 `nc` 连接本机 SOCKS，通过 SOCKS5 握手请求服务端连接公共 DNS 的 TCP/53，再发送 `example.com A` 查询。握手与完整 DNS 应答共享该目标的总超时；校验事务 ID、响应标志、未截断、RCODE=0、问题一致、非空答案及完整帧，只有端口连通或错误响应都不算成功。临时 FIFO、连接和数据在每次结束时回收。它不使用路由器上已有的 WAN 引导 DNS 放行规则；即使校园侧直连公共 DNS 成功，隧道断开时复核仍失败。查询是经隧道送达服务端，再以普通 DNS TCP 发出，不是 DoH。

HTTPS 失败日志包含探测标签、curl 退出码、实际与期望状态码及耗时，不包含目标 URL；DNS 失败记录公共服务器地址、失败阶段及耗时。fallback 应由已配置证书的服务端提供稳定页面；从家庭服务器访问自身公网域名需确保回环路径可达。探测不证明全部互联网、家庭 DNS、TUN 实际转发或反向访问正常，仍需客户端验收。旧配置显式设置 `HEALTH_URL` 却未设置状态码时继续要求 204；未配置 `HEALTH_DNS_SERVERS` 时默认不启用 DNS 复核。迁移时更新健康配置，并清空不再需要的 `HEALTH_FALLBACK_URL`。没有设置主 URL 时自动使用端点 fallback，默认要求 200。

## 流量保护与 DNS

- LAN 只允许转发到同一 LAN 或 `xray0`，没有校园网段、家庭网段或普通 WAN 的直连例外。访问家庭 `192.168.5.0/24` 同样经过隧道。
- IPv4/IPv6 都使用 `iif LAN_IF`、独立策略表 300，避免捕获路由器管理和认证流量。表中常驻高 metric 的拒绝路由；TUN 消失时，不会继续回落查找 WAN 默认路由。
- `NS2_FWD`、`NS2_OUT`、`NS2_DNS` 是项目专有链。过滤规则由 `iptables-restore --noflush` 在单个表中原子提交，IPv4/IPv6 分别提交；不会清空固件整张表，也不会先撤 OUTPUT 再建新白名单。
- 防火墙 hook、模式切换和控制器都调用同一渲染器，以短 `flock` 串行更新。放行前重新读模式和待处理事件，避免旧探测结果覆盖新封锁请求。
- 路由器 WAN 出站仅允许门户、指定的两个 DNS、当前家庭端点的 TLS 端口、DHCP，以及必要的 IPv6 NDP/MLD/错误通知/DHCPv6。普通路由器 HTTP/HTTPS 不会自动走隧道，也不予直接放行；诊断用本地 SOCKS。
- 认证预访问仅临时允许当前家庭端点 IPv4 的 TCP/80，记录有时限的状态，由相同渲染器保留与清理。并发防火墙重载不会把它提前删除。进程强杀后，过期例外在下一次规则重建时撤销。
- IPv4 客户端 53 端口重定向至 dnsmasq。dnsmasq 的 `servers-file`、`resolv-file` 与普通 `server` 上游都移除；只留下 Xray 的 `127.0.0.1:15353` 和家庭端点域名的 WAN DNS 例外。IPv6 不依赖本机不支持的 NAT66；ULA RA 通告路由器 DNS，其他 IPv6 查询按 TUN 路由转发。
- 家庭端点域名是公开 DNS 例外，门户认证也是明文 HTTP；不能将此方案称为“没有任何 DNS/明文流量”。正常业务 DNS 经家庭解析器，必要引导流量除外。
- 安装器禁用 CTF 并要求重启。硬件加速连接可能绕过软件规则，不能在 CTF 开启时承诺这些边界。固件重建网络时，尽早 hook 与策略拒绝路由提供保护；本项目不控制固件运行 hook 之前的所有行为。

## 修改配置与迁移

上传和安装命令见 [首页](../README.md#安装)。安装器先验证 Xray 配置和编码向量，再备份当前目录及五个 hook，建立新保护，停止旧程序、替换文件并清理旧规则。其他插件 hook 内容保留。支持全新安装与同路径升级；更早的独立认证或代理安装需先停止其守护，避免两套入口同时运行。

策略表不要使用 Merlin 的 100、200 或 111–115。当前配置生成器面向 VLESS + TLS + XHTTP stream-one，并固定了 padding 参数；服务端协议不同需要调整生成器并重新验证，不能直接导入任意旧 JSON。二进制由使用者按 [构建说明](XRAY.md) 单独准备。

当前仅保护配置的单个 LAN 桥和单个 WAN；访客桥、多 WAN、额外 VLAN 不在默认保护范围，迁移时必须据此核对拓扑。

配置修改后执行 `netctl.sh check`，通过后执行 `netctl.sh restart`。更换 LAN 网段/接口前先切换 `mode off`，调整固件与配置，再切回 tunnel，以清理旧策略选择器。改密码可运行 `netctl.sh password`，它会安全引用密码并重启控制器，避免旧进程继续使用旧密码。

## 验收与诊断

```sh
D=/jffs/scripts/net-stack
$D/netctl.sh status
$D/netctl.sh auth-status             # 0 在线；1 明确离线；2 查询未知
$D/netctl.sh check                   # Xray 配置 + 离线编码向量
cru l                               # 只应有一条 net-stack-v2 巡检
ip rule; ip -6 rule
ip route show table 300; ip -6 route show table 300
iptables -S NS2_FWD; ip6tables -S NS2_FWD
iptables -S NS2_OUT; ip6tables -S NS2_OUT
sed -n '/>>> net-stack dns/,/<<< net-stack dns/p' /etc/dnsmasq.conf
$D/netctl.sh health                  # 与控制器共用探测；0 健康，非 0 失败
```

正常应为 `mode=tunnel state=tunnel-online gate=allow`，一个控制器、一个 Xray，探测返回 `health_status=0 (0=healthy)`。两个路由表同时有 TUN 默认路由和更低优先级的拒绝路由。IPv6 拒绝路由显示 `unreachable ... error -101` 是预期的兜底，不是当前网络失败。

客户端验收必须绑定接路由器的网卡或源地址；双网卡电脑的普通 `curl` 可能从另一张卡成功，不能证明路由器可用。IPv6 目标不可达时，要区分本地转发与家庭出口限制；不能用一个海外 IPv6 站点的失败断言隧道故障。

日志在 `/tmp/net-stack/{control,daemon,xray}.log`。控制日志含墙上时间和 `+Ns` 开机运行时间；RTC 校时前后请按后者对齐。日志截断轮换，避免 `/tmp` 耗尽。`waiting-wan`、`waiting-auth`、`auth-unknown`、`waiting-endpoint`、`tunnel-unhealthy` 分别标出停在哪一层。

## 回滚

每次安装打印 `/jffs/net-stack-backup-日期-进程号/rollback.sh`，其中保存旧程序、私密配置、hook 和 CTF 原设置。SSH 从 LAN 执行该脚本可以恢复上一版本。恢复 CTF 原值需要再次重启才完全生效。备份包含密码，应保持目录权限 700；核验离线备份后再自行清理旧备份，不要在尚未确认新版本稳定时删除唯一旧版。

仅需临时恢复直连时执行 `netctl.sh mode auth` 或 `mode off`；这是明确选择撤销隧道保护，不是自动故障回退。不要删除 JFFS 目录、清空整张防火墙表或停掉固件 DNS 来排障。

## 兼容性处理

| 已知问题 | 本版处理 |
|---|---|
| 开机 RTC 回到 2024，NTP 不通 | 从门户 HTTP Date 校时；锁与限频使用内核锁/uptime |
| WAN 事件乱序、遗漏，多个入口重复认证 | 事件仅提示检查，唯一循环根据实际状态推进，无永久 WAN_DOWN |
| WAN IP 已出现但门户未就绪 | 检查门户路由；只有状态接口明确离线才尝试登录 |
| `no_response_data_error` 被误认成必然 RADIUS 故障 | 保留已验证的 HTTP 预访问，只记录实际响应，不猜服务端原因 |
| 认证接口接受但实际未在线 | 登录后确认在线 IP；查询未知不当成离线 |
| 手动登录绕过 watcher 限频 | 手动入口只唤醒同一个控制器，所有提交共用 uptime 间隔 |
| 端点 DNS 与隧道 DNS 相互依赖 | 端点域名专用 WAN DNS 例外，其他 DNS 全走家庭 |
| dnsmasq `no-resolv` 无法屏蔽 `servers-file` | postconf 删除所有固件上游后生成本项目配置 |
| Xray dns-out pending request 异常 | 保留 dokodemo-door 转发家庭 DNS，不使用 dns-out 模块 |
| `tun` 模块或 `/dev/net/tun` 缺失 | 启动 Xray 前加载模块、创建字符设备并检查 |
| 无 VFP 导致 Illegal instruction | 保留已验证 GOARM=5 二进制，迁移时显式匹配架构 |
| Go fatal OOM，dmesg 无 OOM killer | 保留 overcommit=2，启动前把 ratio 提至至少 400 |
| 只看进程存活，假死不恢复 | 两次有界健康失败后重启，重启退避避免连接风暴 |
| 冷启动 ELF 载入慢，被误判退出而重复起 Xray | 自己创建的子进程按 PID/启动时刻/父进程确认，容忍 exec 前 argv 尚未变化 |
| `iptables -m comment` 在本机实际插入失败 | 不使用 comment match；用独立 NS2_* 链 |
| IPv6 NAT 表不存在 | 不使用 NAT66，IPv6 经策略路由到 TUN |
| 旧内核 IPv6 路由要设备、replace 重复报 EEXIST | 拒绝路由显式 dev lo；检查存在后 add，不周期 flush |
| BusyBox `nslookup` 的 `Address 1:` 被当成 IPv6 | 校验地址格式，IPv6 至少两个冒号；有对应回归测试 |
| WAN 重建冲掉 LAN ULA、路由与防火墙 | 放行前补地址和策略，firewall hook 同步保护，周期复核 |
| 模式切换后 cron 丢失 | 所有模式统一保留同一条控制器巡检 |
| PID 复用误杀、killall 杀到其他代理 | 验证 PID/内核启动时刻/命令行，只管理本项目进程 |
| 带宽与排队问题误归因于控制脚本 | 不修改家庭服务端、不设置猜测带宽的 tc 整形 |

以上条目来自实机排查，保留已验证的约束与处理方式。`no_response_data_error` 不是特定服务端根因的证明；预访问、当前 DNS 架构和限频行为以 [测试记录](TESTING.md) 为依据。
