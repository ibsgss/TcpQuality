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
- `--province CODE`：仅检测指定省份，可重复；也支持 `-bj`、`-sh`、`-gd` 等省份简写。
- `--debug`：保留临时文件并输出调试信息。

## Star History

<a href="https://www.star-history.com/?repos=ibsgss%2FTcpQuality&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&theme=dark&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=ibsgss/TcpQuality&type=date&legend=top-left&sealed_token=Zs4QOC765auILr4Kt8LKyJ9F2B6_v7FVhAE93bGIGF_kDRms7WxmWT4bZxnJkk-Z8hthp7lXnR-hJxW_eYmEvEgzEtm7KnnOsgkO0zjLz9YvcSlnRuOte0TPYsYgJo0Brf12TkFJ0JGH-xejWEnBE0OZmJAP529da8ou3j5ASigsZ6L6PP2ISBIDa1IV" />
 </picture>
</a>
