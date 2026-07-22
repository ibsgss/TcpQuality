# TcpQuality — Go 版

`runTcpQuality.sh` 的原生 Go 移植版本。功能与原脚本一致：向全国三网（电信 / 联通 /
移动）节点发送裸 TCP SYN 探测丢包与延迟、识别三网回程骨干线路、测试国际互联质量，并对
国内三网做分阶段单线程测速，最后渲染 TUI 表格并可上传报告。

与原脚本不同的是：**探测与路由识别全部用 Go 原生实现，不再依赖 `nping`、`traceroute`、
`nexttrace` 等外部命令。** 除标准库外没有任何 Go 第三方依赖。

## 依赖

- **构建**：Go 1.26+，仅使用标准库（无 `go.sum`，零外部模块）。
- **运行**：Linux + root。裸 SYN 探测与 traceroute 使用原始套接字（`AF_INET/6, SOCK_RAW`），
  需要 `CAP_NET_RAW`（即 root）。
- **分阶段测速**（`--speedtest` / `--only-speedtest` / `--all`）：这是唯一仍需外部工具的部分，
  与原脚本相同——依赖内核 `tc`/`ip`/`nstat`/`modprobe` 做限速与重传统计，并自动下载官方
  `tosutil` 二进制作为测速后端（TOS 协议无法用纯 Go 复刻）。

## 构建与运行

```bash
# 本机构建（建议在 Linux 上）
make build
sudo ./tcpquality

# 从任意平台交叉编译 Linux 二进制
make linux            # 产物在 dist/

# 直接运行
sudo ./tcpquality --all
sudo ./tcpquality -bj -v4 --cernet
sudo ./tcpquality --route --route-protocol both
sudo ./tcpquality --only-speedtest
```

命令行参数与原脚本完全一致，`-h` 查看完整帮助。

## 项目结构

```
cmd/tcpquality/           入口，参数解析与信号处理
internal/
  config/     常量、参数解析、省份代码映射
  iputil/     公网 IPv4/IPv6 校验与本机 IP 栈探测
  nodes/      拉取并解析 getNodes TSV 节点表
  probe/      原生裸 TCP SYN 探测（Linux 原始套接字）+ 丢包/延迟聚合、主备合并
  route/      原生 traceroute + Team Cymru ASN 批量查询 + 三网骨干线路分类
  international/ 国际网站 / CDN TCP 可达性探测
  speedtest/  tosutil + tc/ifb 分阶段测速（Linux）
  render/     CJK 对齐的 TUI 表格、汇总与进度条
  report/     CSV 生成与报告上传
  app/        主流程编排（对应原脚本 main()）
```

平台相关代码用构建标签隔离：`*_linux.go` 为原始套接字 / `tc` 实现，`*_other.go` 在非 Linux
上返回“仅支持 Linux”，因此项目可在任意平台通过 `go build` / `go vet` / `go test`。

## 测试

纯逻辑部分（骨干线路分类、省份映射、参数解析、节点解析、丢包聚合、tosutil 输出解析、
CSV 生成、CJK 列宽、渲染等）均有单元测试：

```bash
make test          # 全部测试
make cover         # 覆盖率
make vet           # go vet（本机 + 交叉 Linux）
```

I/O 边界（原始套接字收发、HTTP、`tc`/`tosutil` 调用）不便在 CI 中单测，已通过接口/构建标签
与可测的纯函数分离。

## 实现说明

- **裸 SYN 探测**：每个源端口唯一，后台 goroutine 统一收包并按目的端口分发；IPv4 手工计算
  TCP 校验和，IPv6 交由内核（`IPV6_CHECKSUM`）。收到 SYN-ACK 或 RST 均计为“已回应”，
  与 `nping` 语义一致；超时 1s 记为丢包，且不触发内核重传。
- **traceroute**：逐跳递增 TTL，TCP 用变化的源端口、UDP 用变化的目的端口，凭 ICMP 差错报文
  内嵌的原始传输头做关联；保留原脚本的 “AS10099 隐藏国内段” TCP 二次重试逻辑。
- **线路分类**：完整移植 `route_label_from_ip_trace` 的 ASN/IP 前缀判定，输出
  CN2GIA / CN2GT / CTGGIA / 163 / 4837 / 9929 / 10099 / CMI / CMIN2 / CERNET(2) 等标签。
