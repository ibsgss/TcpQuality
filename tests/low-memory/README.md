# 128 MiB 低内存回归

对应 [issue 29](https://github.com/ibsgss/TcpQuality/issues/29) 和 [issue 26](https://github.com/ibsgss/TcpQuality/issues/26)。

在仓库根目录执行：

```bash
bash tests/low-memory/run.sh
```

需要 Docker 和支持 `memory.events` / `memory.peak` 的 Linux cgroup v2。测试镜像先在不限内存的构建环境安装依赖，运行容器统一使用 `--memory 128m --memory-swap 128m --network none`，避免 swap 掩盖 OOM。每次创建新的容器，检查退出码、`OOMKilled` 和 `oom_kill`，日志、峰值和 CSV 保存到脚本打印的 `/tmp/tcpquality-low-memory.*` 路径。

- `memory-policy.sh`：覆盖 cgroup v1/v2、无限制哨兵、父级限制、命名空间/子树挂载、物理可用内存、16 MiB 每节点预算和并发上下限、低内存 bpftrace 跳过，以及子进程退出但未写结果时继续调度。
- `results-preservation.sh`：异常退出或任务缺失时保留原始结果，rootfs 将结果移出，正常成功时清理。
- `workload.sh`：使用真实 `main`、路由/探测/国际互联/测速调度和 CSV 写入流程，将网络边界替换为确定性的 24 MiB 工作负载。包含 IPv4/IPv6、教育网、大包、国际互联和测速，验证 92 条 CSV 数据（含 TCP 配置）。传入 `-p 31`，检查 128 MiB 下并发会被内存策略自动压低。该测试验证资源调度，不验证公网线路的准确性。

仅运行不需要 Docker 的测试：

```bash
bash tests/low-memory/memory-policy.sh
bash tests/low-memory/results-preservation.sh
```

验证 chroot 中仍能识别 cgroup（挂载仅发生在临时 Docker 容器内）：

```bash
docker run --rm --memory 128m --memory-swap 128m --cap-add SYS_ADMIN \
  --network none -v "$PWD:/work:ro" tcpquality-low-memory:debian \
  tests/low-memory/chroot-memory.sh --mount
```

## 本次复现与验证

修复基于 `708ba0b`。修复前在 Debian 128 MiB、无 swap 容器运行 `--all -c 1 --no-rank-upload`，旧代码读取到宿主机约 5.8 GiB 内存，选择并发 93；记录到 `oom=11`、`oom_kill=3`，峰值达到 128 MiB。该公网测试在 180 秒时由测试工具超时结束（退出 124），因此没有把超时本身当作 OOM 证据。

修复后在同样内存限制下运行 `--all -bj -c 1 --no-rank-upload`，并设置 `TCPQUALITY_INTERNATIONAL_IPERF_SECONDS=1`、`TCPQUALITY_INTERNATIONAL_IPERF_CONNECT_TIMEOUT_MS=200`，并发为 1，四阶段完成并生成 CSV，退出 0，峰值约 28.5 MiB，`oom=0`、`oom_kill=0`。此公网测试限定北京节点；没有可用 IPv6，镜像未安装 nexttrace-tiny，相关项目按原有逻辑跳过。IPv6 和大包调度由确定性工作负载覆盖。

最终代码在 Alpine 128 MiB、无 swap 环境也运行了同样的公网四阶段测试（额外设置 `TOS_TIMEOUT=2`），退出 0 并生成 CSV，`oom=0`、`oom_kill=0`，峰值约 35.6 MiB。个别测速节点因短超时显示 `failed`，测试流程仍正常结束。

Debian 和 Alpine 的离线四阶段测试均完成并生成 93 行 CSV，未发生 OOM；本次峰值分别约 50.3 MiB 和 41.7 MiB，实际峰值随镜像和内核缓存情况变化。两种发行版的 chroot 测试也确认总内存识别为 128 MiB、并发为 1。

本次日志位于 `/tmp/tcpquality-low-memory-results`（公网复现/验证）和 `/tmp/tcpquality-low-memory.FrCziT`（最终离线回归）。

异常结果保留用于排查，不提供断点续测。SIGKILL 或系统重启不能保证执行 shell 清理逻辑；这里的主要修复是避免过量并发触发 OOM。
