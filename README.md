# TcpQuality

TCP 质量检测脚本，默认检测全国三网运营商节点。

## 快速运行

国外服务器推荐使用 GitHub Raw：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
```

国内服务器推荐使用加速入口：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run)
```

示例报告：

https://tcpquality.ibsgss.uk/r/3-xsaeoJDH

![TcpQuality 示例报告](https://tcpquality.ibsgss.uk/r/3-xsaeoJDH.svg)

## 支持参数

- `-h`、`--help`：显示帮助信息并退出。
- `-c NUM`、`--count NUM`：设置每个节点的发包数量，默认 30。
- `-s NUM`、`--size NUM`：指定 IP 包总长度，单位为 B；`0` 表示标准无负载 SYN，未指定时随机使用内置包长，过小的数值按协议最小头部发送。
- `-p NUM`、`--parallel NUM`：设置并行节点数，范围 1-31，默认 16。
- `-v4`、`--v4`：仅探测 IPv4。
- `-v6`、`--v6`：仅探测 IPv6。
- `--cernet`：仅探测 CERNET IPv4 和 CERNET2 IPv6。
- `--all`：检测三网、CERNET 和 CERNET2；出现 `--all` 时会探测全部可用 IP 协议。
- `--province CODE`：仅检测指定省份，可重复；也支持 `-bj`、`-sh`、`-gd` 等省份简写。
- `--debug`：保留临时文件并输出调试信息。
