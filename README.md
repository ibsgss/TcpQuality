# TcpQuality

TCP 质量检测脚本，默认检测全国三网运营商节点。[单线程测速排行榜](https://tcpquality.ibsgss.uk/rank)

## 快速运行

国外服务器推荐使用 GitHub Raw：

```
# bash / zsh
bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
```

```
# fish
curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh | env TERM=xterm bash
```

国内服务器推荐使用加速入口：

```bash
# bash / zsh
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run)
```
```bash
# fish
curl -fsSL https://tcpquality.ibsgss.uk/run | env TERM=xterm bash
```

示例报告：

- https://tcpquality.ibsgss.uk/r/hUETeLqqyF

<table>
  <tr>
    <td><img src="https://tcpquality.ibsgss.uk/r/hUETeLqqyF.png?section=large4" alt="IPv4大包回程" width="100%"></td>
    <td><img src="https://tcpquality.ibsgss.uk/r/q1ECAn_b5D.png?section=speedtest" alt="单线程测速" width="100%"></td>
  </tr>
</table>

## 支持参数

- `-h`、`--help`：显示帮助信息并退出。
- `-c NUM`、`--count NUM`：设置每个节点的发包数量，范围 1-600，默认 30。
- `-s NUM`、`--size NUM`：指定 IP 包总长度，单位为 B；`0` 表示标准无负载 SYN，未指定时随机使用内置包长，过小的数值按协议最小头部发送。
- `-p NUM`、`--parallel NUM`：设置并行节点数，范围 1-31，默认 16。
- `-v4`、`--v4`：仅探测 IPv4。
- `-v6`、`--v6`：仅探测 IPv6。
- `--only-large`：仅探测 IPv4大包回程。
- `--cernet`：仅探测 CERNET IPv4 和 CERNET2 IPv6。
- `--all`：检测 IPv4/IPv6、CERNET/CERNET2、国际互联和单线程测速。
- `--speedtest`：完成 TCP 质量探测后，追加单线程测速。
- `--only-speedtest`：仅运行单线程测速。
- `--intl`：单独使用时仅运行国际互联；与 `-v4`、`-v6`、`--all` 等组合时追加国际互联。
- 国际互联探测包含 Telegram DC1–DC5；地址和端口从中央 `getNodes` 服务获取，中央服务每 5 分钟刷新一次，自动检测可用 IPv4/IPv6 并跳过不可用地址族。服务不可用时使用内置引导地址兜底。
- `--province CODE`：仅检测指定省份，可重复；也支持 `-bj`、`-sh`、`-gd` 等省份简写。
- `--debug`：保留临时文件并输出调试信息。

## IPv6 补充工具: 大包回程 + 单线程测速

主流程的大包回程(`--only-large`)与单线程测速目前仅覆盖 IPv4; `runTcpQuality-v6.sh` 补齐对应的两项 IPv6 能力, 方法论与 IPv4 实现一致:

- `--large`: `nping -6 --tcp --flags syn --data-length`(on-wire ≤1200B)按尺寸统计丢包率与平均 RTT; v6 裸 SYN 源地址为 `::` 必丢, 自动切换 L2 模式(`-S/-e/--source-mac/--dest-mac`, 与核心脚本 `IPV6_NPING_FORCE_L2` 处理一致); 逐目标先做 TCP 预检, 不可达目标标记跳过, 避免与"大包"问题混淆
- `--route`: nexttrace-tiny TCP 1200B 回程路由识别(同 IPv4 大包回程)
- `--speed`: `curl -6` 单线程下行/上行测速, 固定目标 `speed.cloudflare.com` 的 `__down`/`__up` 端点, 每次仅一个连接, 输出均值/峰值与连接/TLS/首包耗时拆解

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality-v6.sh) --all
```

依赖: `nmap`(nping)、`curl`; `nexttrace-tiny` 可选(仅 `--route`)。环境变量 `DOWN_BYTES`/`UP_BYTES`/`COUNT` 可调测试强度。

## 许可证

本项目原创代码采用 GPL-3.0-only，详见 [LICENSE](LICENSE)。预构建 rootfs 中的 Debian 软件包、NextTrace/nexttrace-tiny 等第三方组件仍按各自许可证授权；再分发时须遵守其许可条款。

## Star History

<a href="https://www.star-history.com/?repos=ibsgss%2FTcpQuality&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&theme=dark&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
 </picture>
</a>
