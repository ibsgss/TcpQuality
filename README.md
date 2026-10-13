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
- `-p NUM`、`--parallel NUM`：设置并行节点数上限，范围 1-31，默认根据可用内存自动选择；内存不足时会调低手动指定的上限。
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

## 低内存机器

启动和最终报告会显示实际采用的并行节点数；仅运行单线程测速时显示 1。

并发预算同时考虑物理可用内存和当前进程的 cgroup v1/v2 内存限制（包括可见的父级限制），不使用 swap 扩大并发。预留 48 MiB 后，每个节点预算 24 MiB，向下取整，范围为 1–31；128 MiB 环境通常运行 2–3 个并行节点。`-p 1` 可指定串行测试。可用内存不足 256 MiB 时跳过 bpftrace 编译，继续使用 TCP_INFO/ss 测量重传。

普通异常退出会保留 `/tmp/tcpquality-results.*` 中的原始中间结果；rootfs 模式会将其移到输出目录（默认宿主机 `/tmp`）。这些文件用于排查，不支持断点续测。SSH 连接不稳定时，可在 `tmux` 或 `nohup` 中运行。

可复现的 128 MiB Docker 回归测试见 [tests/low-memory/README.md](tests/low-memory/README.md)。

## 报告上传排查

报告上传失败时会显示 curl 退出码或 HTTP 状态码、可用的错误原因及本地 CSV 路径。上传失败不会删除已生成的 CSV。`--debug` 还会保存接口响应和 curl 错误，便于区分连接超时、TLS 问题和服务端错误。

## Star History

<a href="https://www.star-history.com/?repos=ibsgss%2FTcpQuality&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&theme=dark&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
 </picture>
</a>
