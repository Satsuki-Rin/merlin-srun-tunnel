# Xray 构建与来源

[返回首页](../README.md)

本项目通过命令行启动独立的 [XTLS/Xray-core](https://github.com/XTLS/Xray-core)，不包含其源码或可执行文件。需要支持 TUN、VLESS、TLS、XHTTP stream-one、SOCKS 和 dokodemo-door 的版本。仅文件名或架构匹配不足以证明它能在目标旧内核运行。

## 实测二进制

| 项目 | 记录 |
| --- | --- |
| 版本输出 | Xray 26.11.9 Custom |
| Go 构建信息 | go1.27.4，`GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0` |
| 文件类型 | Linux ARM EABI5，静态链接，软浮点 |
| SHA-256 | `422d39d3576ad92f0e1928a3a56ec12f50ef82ae32449cfeea608a318cc5804a` |
| 验证环境 | RT-AC68U，Merlin 386.14.2，Linux 2.6.36.4 |

此文件来自已运行的设备。原构建记录使用上游 `v26.11.9` 源码和下面的编译参数；`go version -m` 显示主模块为 `(devel)`，没有嵌入 VCS revision。因此这里记录的是已测文件的身份，不承诺按命令重建后逐字节一致，也没有把它作为 GitHub 发布附件。

## 交叉编译

在安装了对应 Go 工具链的开发机上执行。源码下载到项目仓库以外的目录；输出路径改为自己的项目位置。

```sh
git clone --depth 1 --branch v26.11.9 https://github.com/XTLS/Xray-core.git /tmp/xray-core-build
cd /tmp/xray-core-build
GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 \
    go build -trimpath -ldflags '-s -w' -o /tmp/xray-arm-softfloat ./main
file /tmp/xray-arm-softfloat
go version -m /tmp/xray-arm-softfloat
sha256sum /tmp/xray-arm-softfloat
```

RT-AC68U 的实测固件未提供 VFP 支持；官方 ARMv7 硬浮点构建可能直接报 `Illegal instruction`。其他设备按 CPU 和内核选择目标，不能一律套用 `GOARM=5`。升级 Go 或 Xray 后，应重新验证旧内核兼容性、配置加载、冷启动、双栈和故障恢复。安装器会在路由器上执行 `xray run -test`，但这一检查不能替代运行测试。

## 上游许可

Xray-core 使用 [Mozilla Public License 2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE)，其依赖可能采用其他许可证。本仓库的 MIT 许可不替代这些上游条款。若另行分发 Xray 二进制，需要保留适用的许可证和声明，并按上游要求提供对应源码及修改；不能只附本项目的 MIT 文件。

`xencode.awk` 从本项目既有认证实现保留，用于兼容门户的 SRBX1 编码。它不是 Xray 的源码文件；其协议约束与编码向量记录在 [运行与配置](OPERATIONS.md) 和 [测试说明](TESTING.md) 中。
