# 测试方法与实机记录

[返回首页](../README.md) · [运行与配置](OPERATIONS.md)

## 如何运行

开发机使用 Linux、Python 3.10+ 和 `/bin/sh`，没有 Python 第三方依赖：

```sh
sh -n netctl.sh && sh -n install.sh
python3 -m unittest discover -s tests -v
python3 tests/live.py --help
```

隔离回归不连接路由器，不需要真实账号或 Xray。GitHub Actions 仅运行这一层及命令入口检查。

实机脚本通过 SSH 工作，默认使用 SSH 密钥或交互认证；需要密码时可通过 `SSHPASS` 配合已安装的 `sshpass` 使用。主机密钥应先通过正常 SSH 连接核验，不关闭主机校验。

```sh
export ROUTER=admin@192.168.50.1   # 改为目标设备
python3 tests/live.py baseline
# 下列场景会切换网络、停止进程或重启设备，逐项执行。
python3 tests/live.py modes
python3 tests/live.py crash
python3 tests/live.py hang
python3 tests/live.py firewall
python3 tests/live.py daemon
python3 tests/live.py wan
python3 tests/live.py reboot
```

`baseline` 要求 tunnel-online，检查当前配置的 SOCKS 健康探测、巡检和遗留进程。结果默认写入 Git 忽略的 `artifacts/live-results.json`；可用 `LIVE_RESULTS` 指向仓库外的文件。原始结果可能含拓扑信息，公开前需脱敏。

`clients` 和 `policy` 还需要以下变量。必须从目标 LAN 发起，不能依赖双网卡电脑的默认路由。`policy` 先确认客户端连通，再暂停控制器并杀死 Xray，验证拒绝转发，最后恢复控制器。

| 环境变量 | 含义 |
| --- | --- |
| `LAN4`、`LAN6` | 客户端连接目标路由器的 IPv4、IPv6 源地址，不含前缀长度 |
| `ROUTER_DNS4`、`ROUTER_DNS6` | 路由器 LAN 的 IPv4、IPv6 DNS 地址 |
| `HTTP4_IP`、`HTTP6_IP` | HTTPS 测试域名当前有效的 A、AAAA；显式指定以排除另一网卡的 DNS 干扰 |
| `HTTP4_HOST`、`HTTP6_HOST` | 对应的 HTTPS 域名；默认 `www.baidu.com`、`ipv6.baidu.com`，需要返回 200 |
| `CLIENT_CURL` | 可选，客户端 curl 路径；默认 `curl` |
| `POWERSHELL` | 可选，WSL 下 Windows PowerShell 路径；设置后通过 Windows 发起 DNS 请求 |

原生 Linux 使用 curl 和 Python socket。WSL 若通过 Windows 网卡验收，同时将 `CLIENT_CURL` 设为 Windows `curl.exe`、`POWERSHELL` 设为 `powershell.exe` 的完整路径，并填写 Windows 网卡的 `LAN4/LAN6`。脚本不携带实测主机的地址。

```sh
# 设置上述变量后执行；policy 会暂时切断 LAN 的隧道转发。
python3 tests/live.py clients
python3 tests/live.py policy
```

## 实测环境

测试日期：2026-11-13。设备：RT-AC68U、Merlin 386.14.2、Linux 2.6.36.4brcmarm、BusyBox 1.25.1。旧版本和新版本共用原有 GOARM=5 Xray 二进制与实际校园/家庭配置。

## 离线回归

执行 `python3 -m unittest discover -s tests -v`。当前 37 项，覆盖：

- 在线、明确离线、HTTP/解析错误和在线 IP 不匹配；未知状态不发登录。
- HTTP 预访问先于 challenge/login；登录接受但仍离线不能报成功。
- 多次事件、独立新进程不能绕过全局登录间隔。
- WAN 未就绪后自行恢复、冷启动等待、校时失败后重试，无永久暂停标记。
- 存活但健康失败的代理重启、DNS 失败保留成功缓存、无缓存不启动代理。
- 所有模式重装同一 cron；并发启动只进入一个控制循环；PID 复用和 exec 前子进程身份。
- 单表事务防火墙更新、封锁与放行边界、临时认证例外保留及过期、必要 IPv6 控制协议。
- 过期放行结果不能覆盖 off 或待处理事件。
- dnsmasq 清除所有外部上游、重复执行幂等、ULA 参数可迁移。
- Xray JSON 由统一配置生成；无效配置和过快限频拒绝。
- BusyBox DNS 序号不被当成 IPv6，两个 DNS 服务器结果合并。
- 自有 fallback 返回 200、主探测超时后的备用复核、全部探测失败、错误状态码、证书/传输失败不能假成功、本地服务缺失不能被外部探测掩盖。
- 备用探测成功时不封锁或重启，下一次探测从本次完成后计时，旧配置默认状态码兼容。
- 已放行 TUN 的一次网络失败可恢复；本地服务缺失与冷启动不能借该容错放行，连续失败仍阻断并重启。

另外在目标路由器执行 Shell 语法检查、Xray `run -test` 和 7 个离线编码/加密向量，全部通过。编码核心保留原来经过门户验证的实现，不重写为另一种算法。

## 实机故障与功能验收

| 场景 | 操作与结果 |
|---|---|
| 模式切换 | tunnel → off → auth → tunnel；off/auth 撤除规则、停止 Xray；切回隧道恢复，始终只有一条 cron；该轮约 41 秒 |
| Xray 崩溃 | SIGKILL 正在运行的 Xray；自动建立新进程、恢复 allow，约 8.5 秒 |
| Xray 假死 | SIGSTOP Xray；健康检查失败后 block，强制回收并重启，约 70 秒 |
| 控制器崩溃 | SIGKILL 控制器；cron 自动重建单实例并恢复，该轮约 19 秒（最坏等待取决于 cron 相位） |
| WAN 离线认证 | 先 off、注销并确认门户离线，再 stop_wan、切 tunnel、start_wan；保持 block，自动预访问、登录确认和隧道恢复，WAN 启动后约 49 秒 |
| 防火墙重建 | 建立测试链后 `restart_firewall`，确认测试链确实被固件清除；项目 hook 恢复规则，约 8 秒完成该轮 |
| 乱序并发事件 | 并发发送 stopped/connected/disconnected/connecting/connected，加四次 start；恢复 allow，仅一个控制器与一个 Xray，没有额外登录 |
| LAN IPv4/IPv6 HTTPS | 从 Windows 客户端分别绑定路由器网卡的 IPv4/ULA 源地址；百度 IPv4 和 IPv6 HTTPS 均返回 200 |
| DNS | 显式向路由器 IPv4/ULA 发 UDP DNS，IPv4 TCP DNS，以及指定 8.8.8.8 的 UDP DNS，均收到有效应答；配置只保留隧道上游和端点例外 |
| 无守护时的转发兜底 | 暂停控制器并强杀 Xray，TUN 默认路由消失，只剩双栈拒绝后备；绑定 LAN 的 IPv4/IPv6 HTTPS 均失败，未缓存 DNS 无法回落成功 |
| 路由器自身出站限制 | 上述故障期间，路由器直连普通公网 HTTPS 返回 000；SSH 管理保持可用；恢复控制器后自动恢复隧道 |
| 重复安装 | 已在最终 v2 上再次运行安装器；五个 hook 均只有一个标记块、一条 cron、双栈各一个 FORWARD 入口；隧道和客户端测试恢复通过 |
| 回滚 | 实际执行 rollback.sh，恢复原实现，确认原 gate=allow、SOCKS=204；随后用新版安装器再次迁移成功 |
| 重启 | 已执行软件重启和明确离线后的最终版本重启；最终版本开机 +67s 校时、+79s 预访问、+80s 确认认证、+82s 启动唯一 Xray、+102s 放行；未出现重复启动或资源忙错误 |

耗时为对应测试轮次的实际观测，包含探测、退避和测试等待，不能视为稳定的性能保证。早期一次 `restart_firewall` 仅等待状态，不足以证明固件完成重载，后续已增加测试链消失条件并重新通过。

最终离线重启的关键日志：

```text
[2024-01-01 08:00:46 +45s] controller started pid=1383
[2024-01-01 08:00:52 +51s] mode=tunnel
[2024-01-01 08:00:53 +52s] waiting-wan
[2024-01-01 08:00:59 +58s] settling-wan
[2026-11-13 14:19:36 +67s] clock corrected from portal HTTP Date
[2026-11-13 14:19:48 +79s] bootstrap HTTP=200
[2026-11-13 14:19:49 +80s] authentication: submit login
[2026-11-13 14:19:49 +80s] authentication: confirmed online
[2026-11-13 14:19:51 +82s] xray started pid=3889
[2026-11-13 14:19:55 +86s] tunnel-unhealthy
[2026-11-13 14:20:10 +102s] tunnel-online
```

## 测试中修正的问题

1. 老内核 IPv6 拒绝路由需要显式 `dev lo`，对已有路由 `replace` 会返回 EEXIST；已改为检查后添加，实际路由存在时重复执行成功。
2. BusyBox `nslookup` 输出的 `Address 1:` 中序号曾被识别为 IPv6；已增加格式校验与回归测试。
3. 开机 JFFS 读取 30 MB ELF 较慢，子进程在 exec 完成前还显示 shell 命令行，曾被判成退出并重复拉起。已改为同时验证 PID、启动时刻和本进程的子进程关系；最终离线重启检查只启动一个 Xray。
4. 宿主机为双网卡，普通 curl 不可靠。客户端验收改用 Windows curl 绑定 LAN 源地址和明确 DNS 目标；IPv6 目标用已确认 AAAA 地址进行独立转发验收，避免宿主机其他 DNS/网卡干扰。

## 健康探测修复验收

2026-11-13 后续运行中发现，单个 Google generate_204 探测偶发超时会立即封锁整个 LAN；经相同 SOCKS 请求其他网站仍可能成功。只更换站点也不能解决所有问题，服务端 fallback 和独立公网探测同样观察到偶发超时或连接重置。

修复后以服务端 HTTPS fallback 为主探测，精确要求配置的 200；独立备用目标要求 204。首次完整网络探测失败只把已放行隧道记为 degraded，连续失败才封锁重启，本地故障与冷启动保持保护。37 项隔离回归全部通过；目标路由器验证如下：

| 场景 | 结果 |
| --- | --- |
| 正常 fallback | 经 SOCKS 完成 HTTPS 请求，证书验证通过、HTTP 200；新 health 命令返回 0 |
| 主探测故意指向拒绝连接的目标 | 同一套实际探测函数使用备用 HTTPS 目标成功确认；两个目的地都失败时返回非 0，日志记录退出码、状态码与耗时 |
| 最终版本 Xray 假死 | SIGSTOP 后先 degraded，随后 block、回收旧 PID、退避并启动新进程，恢复 online；完整场景约 120.6 秒，包含等待部署后的初始化 |
| 客户端双栈和 DNS | 绑定 LAN 网卡的 IPv4/IPv6 HTTPS 返回 200；路由器 DNS 的 UDP/TCP 与 IPv6 DNS 返回有效应答 |
| 暂停控制器并杀死 Xray | 双栈业务连接失败、未缓存 DNS 无法直连回落、路由保留拒绝后备、路由器普通 HTTPS 直连失败；恢复后约 56.6 秒完成整轮测试，最终基线通过 |

实机测试等待恢复时同时检查控制器与 Xray 的有效 PID，防止强杀后旧的 online 状态文本被误当成已经恢复。客户端测试中曾有单次 TLS reset，随后单独复核及完整客户端轮次通过；不将这次修复描述为消除了全部上游或无线网络抖动，也不宣称修复了之前尚未定位的所有 SSH 超时。

## 测试边界

- 已测软件重启，没有操作物理断电，也没有验证掉电中途的 flash 写入恢复。
- 已做故障注入与多轮恢复，没有宣称数天/数周的长期稳定性。
- 不修改真实校园密码来制造错误，也不对门户做高频失败请求；认证拒绝、未知响应与限频边界由隔离回归覆盖。
- 没有权限改变家庭 DDNS 的实际公网记录；地址变化处理和 DNS 失败路径用隔离测试、缓存/规则检查验证，不能冒充真实运营商换 IP 测试。
- 目标为当前单 LAN、单 WAN 拓扑；未验证访客桥、多 WAN、不同 CPU/固件与不同校园门户。
- CTF 已禁用并重启确认模块不加载。观察到的防泄漏结果涵盖已列明的测试流量，不代表证明固件在 hook 执行前的所有瞬间都无泄漏。

这里保留脱敏后的验收结论，不分发原始日志、私密配置或设备备份。回滚记录说明当时测试成功，不代表某个历史备份现在仍然存在；实际可用路径以每次安装输出为准。
