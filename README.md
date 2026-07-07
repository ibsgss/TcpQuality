# TcpQuality

TCP 重传检测脚本，默认检测三网节点。每节点单发 30 次裸 TCP SYN，默认并行 16，检测完成后自动上传报告并返回公开链接。

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

https://tcpquality.ibsgss.uk/r/SEHqm2mczV

![TcpQuality 示例报告](https://tcpquality.ibsgss.uk/r/SEHqm2mczV.svg)

---

## 常用示例

查看帮助：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) -h
```

指定每节点发包数，例如 100：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) -c 100
```

检测三网并增加 CERNET IPv4 和 CERNET2 IPv6：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) --cernet
```

检测三网、CERNET 和 CERNET2：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) --all
```

仅检测 IPv4 三网 + CERNET：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) --v4 --cernet
```

仅检测 IPv6 三网 + CERNET2：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) --v6 --cernet
```

设置并行节点数，例如 16：

```bash
bash <(curl -fsSL https://tcpquality.ibsgss.uk/run) -p 16
```

## 支持参数

- `-h`、`--help`：显示帮助信息并退出。
- `-c NUM`、`--count NUM`：设置每个节点的发包数量，默认 30。
- `-p NUM`、`--parallel NUM`：设置并行节点数，范围 1-31，默认 16。
- `-v4`、`--v4`：仅探测 IPv4。
- `-v6`、`--v6`：仅探测 IPv6。
- `--cernet`：在三网基础上增加 CERNET IPv4 和 CERNET2 IPv6。
- `--all`：检测三网、CERNET 和 CERNET2；出现 `--all` 时会探测全部可用 IP 协议。

脚本仅检测本机可用的 IP 协议；缺少 IPv4 或 IPv6 时会自动跳过对应节点。发送 TCP SYN 探测包通常需要使用 `root` 用户运行。IPv4 会跳过私网、保留地址和 `198.18.0.0/15` 测试网段。

SVG 报告默认提交到 `https://tcpquality.ibsgss.uk/generate`，由报告服务生成并保存。
