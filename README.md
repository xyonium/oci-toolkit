# oci-toolkit — 甲骨文云 (OCI) 运维工具集

面向 Oracle Cloud Infrastructure (OCI) 免费层/付费租户的轻量运维脚本合集。纯 Bash + 官方 OCI CLI，无其他依赖，适合放在家里的小主机/NAS 上常驻运行。

## 包含工具

### 1. `launch-from-bv.sh` — 基于已有引导卷自动重开 ARM 实例

针对「实例被终止但引导卷还在」的场景（例如 Oracle 2026-08-18 强制执行免费层新限额后 4 OCPU/24GB 实例被自动回收）。脚本在指定可用域持续轮询，容量释放的瞬间以**原引导卷**为启动源开机——系统、数据、配置原样保留，无需重装迁移。

特性：

- 以 `--source-boot-volume-id` 直接挂原盘启动（AD 严格对齐引导卷所在可用域）
- 错误分级：容量类错误（Out of host capacity / InternalError / 429）继续轮询；配置类错误（LimitExceeded / NotAuthorizedOrNotFound / InvalidParameter / Conflict）**立即停止**，绝不空转
- `--no-retry` 禁用 OCI SDK 内部静默重试，轮询间隔真实可控
- 成功后自动等待实例 RUNNING 并抓取公网 IPv4 / IPv6，写醒目日志后收工
- `--dry-run` 干跑模式，打印将要执行的完整命令
- systemd user 服务模板，开机自启、崩溃自拉、不依赖 sudo（enable-linger 一步除外）

### 2. `setup-vcn.sh` — 补齐 default VCN 的网络缺口（幂等）

新建的 OCI 租户会自动带一个双栈 `default-vcn`，但**缺少互联网出口与业务防火墙规则**。本脚本只补缺，不重复创建任何已存在的东西，可反复运行：

- Internet Gateway：不存在才创建
- 默认路由表：补 `0.0.0.0/0` 与 `::/0` 两条默认路由指向 IGW（双栈出网）
- 默认安全列表：**合并追加**业务入站规则（SSH/ICMP/egress 这些系统默认规则原样保留，不重复）

规则从旧租户 1:1 复刻，v4/v6 成对：SSH 22、HTTP/HTTPS 80/443/8443、http-alt 8080-8880、ZeroTier（tcp 9000-65535 / udp 9993-65535）、coturn（3478-3479、5349-5350、8448）、VNC（5901、6001）、bitmag（3333-3334 / udp 3334）。

```bash
./setup-vcn.sh --dry-run   # 只做只读查询 + 打印将要执行的变更
./setup-vcn.sh             # 真跑（可重复，第二次会提示"已存在/无新增"）
```

### 3. `launch-vm.sh` — 按最新 LTS 镜像开机（x86 即时 / ARM 轮询）

镜像 OCID 每次运行时查询最新的 Ubuntu 24.04，不写死。配置见 `.env.uk.example`。

```bash
./launch-vm.sh --x86            # 开 X86_NAMES 里的微机（即时，幂等跳过已存在的）
./launch-vm.sh --arm --once     # 试一次 ARM（退出码 3 = 参数正确但没有容量）
./launch-vm.sh --arm            # 常驻轮询抢 A1.Flex（挂 systemd）
./launch-vm.sh --x86 --dry-run  # 打印将要执行的完整命令
```

ARM 模式：多 AD 轮换尝试（比单 AD 机会多）、200s 基准 + 0~100s 随机抖动、错误分级、`--no-retry` 保证轮询节奏真实可控、成功后写 `logs/.success-vm-arm` 防重复开机。

systemd 单元建议带 `RestartPreventExitStatus=1`：退出码 1 表示参数/权限类不可重试错误，重启只会同样失败并刷日志；其他非 0 退出正常重启。

退出码：`0` 成功 / `1` 不可重试错误 / `2` 未知响应 / `3` 单次尝试未获得容量。

### 4. `init-iptables.sh` — 迁移 iptables 放行规则（v4 + v6 对称）

```bash
./init-iptables.sh ubuntu@<host> [ubuntu@<host2> ...]        # 默认 dry-run
./init-iptables.sh ubuntu@<host> --apply                      # 实际执行
```

把旧主机上自配的 INPUT 放行规则补到新主机，**IPv4 与 IPv6 对称**。幂等（已存在则跳过），默认 dry-run。

实测对比 4 台主机后确认的规则构成（详见脚本头部注释）：

- Oracle 镜像自带的 `InstanceServices` 链（`169.254.0.0/16` 那批）**原样保留，不复制**
- 放行规则全部是**纯端口匹配**，无一条绑定私有地址 → 可 1:1 翻译到 v6
- 4 台的 `rules.v6` 原本都只有空表头；旧机内核里的 ip6tables 规则全是 **Docker 自建链**，由 Docker 自行管理，写进持久化文件会与 Docker 争抢规则，故不迁移

**v6 与 v4 的两处关键差异**（照抄会出事）：

1. **ICMPv6 不能当可选项**。它承担邻居发现（等价 IPv4 的 ARP）、PMTUD、SLAAC 地址重复检测。若照抄 v4 的 `-p icmp` 再加 REJECT 兜底，可能让 DAD 失败、IPv6 整体中断 → 脚本用 `-p ipv6-icmp` 显式全放行。
2. **REJECT 类型不同**：v4 用 `icmp-host-prohibited`，v6 用 `icmp6-adm-prohibited`。

**顺序约束**：默认策略是 `ACCEPT`，靠链尾一条 `-A INPUT -j REJECT` 兜底。所有放行规则必须插在它**之前**（用 `-I <行号>` 而非 `-A`），否则永不生效；v6 原本没有兜底，须在放行规则全部就位**之后**补建。首版漏补 v6 INPUT 兜底，导致 11 条 ACCEPT 形同虚设（policy ACCEPT = 全放行），已修。

安全闸门：持久化前校验 22 端口在两栈放行列表内，否则拒绝 `netfilter-persistent save`，避免把自己锁在门外。

### 5. `gather-iptables.sh` — 采集多台主机的 iptables 配置

```bash
./gather-iptables.sh ubuntu@host1 ubuntu@host2 ...
```

输出到 `iptables-dump/<host>/`：持久化文件的**字节数与规则条数**（用于判断 rules.v6 是否真为空）、磁盘上的 `rules.v4`/`rules.v6`、内核里实际生效的 live 规则（能看出有无未保存改动）、接口地址（识别绑定私有 IP 的规则）。对比新旧主机时的第一步。

### 6. `cross-region-copy.sh` — 引导卷跨区复制（规划中）

TODO：定期把指定引导卷备份/复制到另一个区域，异地容灾。

## 快速开始

```bash
# 1. 在任意有网的 Linux 主机上
git clone https://github.com/xyonium/oci-toolkit.git
cd oci-toolkit

# 2. 安装 OCI CLI（venv 隔离，不动系统 Python）
./setup.sh            # 含 venv + oci-cli + systemd 单元 + enable-linger

# 3. 填配置
cp .env.example .env      # 场景一：基于已有引导卷复活实例
cp .env.uk.example .env   # 场景二：新租户搭双栈网络 + 开新机

# 4. 干跑验证
./launch-from-bv.sh --dry-run    # 或 ./launch-vm.sh --x86 --dry-run
./setup-vcn.sh --dry-run         # 新租户补齐网络

# 5. 单次真实调用验证
./launch-from-bv.sh --once       # 预期 Out of host capacity = 参数全对，只差容量
./launch-vm.sh --arm --once      # 退出码 3 = 参数正确但没抢到容量

# 6. 挂到 systemd 常驻轮询
./setup.sh enable
tail -f logs/launch.log
```

### 多租户

凭据用 OCI CLI 的 INI 多 profile 共存，互不干扰：

```ini
# ~/.oci/config
[DEFAULT]      # 旧租户
[uk]           # 新租户 —— 脚本里 OCI_PROFILE=uk
```

新私钥用**新文件名**（如 `uk_api_key.pem`），不要覆盖旧租户的 `.pem`。

## 需要准备的 OCID

| 变量 | 获取方式 |
|---|---|
| `COMPARTMENT_ID` | 控制台租户信息，或 `oci iam compartment list` |
| `BOOT_VOLUME_ID` | 存储 → 块存储 → 引导卷 → 复制 OCID（注意其可用域！） |
| `TARGET_AD` | 引导卷详情页的「可用性域」，必须与卷完全一致 |
| `SUBNET_ID` | 网络 → 虚拟云网络 → 子网 → 复制 OCID |

凭据：`oci setup config` 生成 `~/.oci/config` + API Key（控制台 → 用户设置 → API 密钥）。

## 背景：2026 免费层限额变更

- 2026-06-15 起，Always Free 的 Ampere A1 额度从 4 OCPU/24GB 砍半为 **2 OCPU/12GB**（1500 OCPU-小时 + 9000 GB-小时/月）
- 2026-08-18 起 Oracle 强制执行，超额实例被自动终止
- 引导卷会被保留（`free-tier-retained` 标记），因此可以用本工具在 2/12 规格下原盘复活

参考：[Oracle Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)

## 目录结构

```
oci-toolkit/
├── .env.example          # 配置模板：基于引导卷复活（复制为 .env 使用，已被 gitignore）
├── .env.uk.example       # 配置模板：新租户搭网 + 开机
├── launch-from-bv.sh     # 基于已有引导卷自动重开 ARM 实例
├── setup-vcn.sh          # 幂等补齐 default VCN 的互联网出口与防火墙规则
├── launch-vm.sh          # 按最新 LTS 镜像开机（x86 即时 / ARM 多 AD 轮询）
├── init-iptables.sh      # 迁移 iptables 放行规则（v4 + v6 对称，幂等，默认 dry-run）
├── gather-iptables.sh    # 采集多台主机的 iptables 配置用于对比
├── check-arm.sh          # 一条命令查看 JP/UK 两个 ARM 轮询的状态与进度
├── setup.sh              # 安装 + systemd 服务管理
├── docs/                 # 设计文档
└── README.md
```

## 实测约束（踩过的坑）

- **引导卷最小 50GB**。OCI 会拒绝更小的请求（`Requested volume size 47GB is not in the allowed range`）。旧账户里 47GB 的卷是 2021 年的遗留值，现在建不出来。
- **Always Free 块存储共 200GB**（home region 内，引导卷 + 块卷合计）。典型分配：2 台 x86 各 50GB + 1 台 ARM 100GB。
- **shape 与 AD 相关**：某 AD 不提供某 shape 时返回 `NotAuthorizedOrNotFound`（404），不是权限问题。换 AD 试试。
- **单个 AD 的 404 不能当全局错误**。多 AD 轮询时若把某个 AD 的 404 一律视为不可重试，会导致整个轮询退出；配合 systemd 的 `RestartPreventExitStatus=1`，轮询会**永久停摆且无人察觉**（实测静默死了 2 小时）。正确做法：移出该 AD 继续轮换，只剩最后一个 AD 时才认定是凭证/ compartment 问题。移除元素后索引要回退一格，否则会跳过一个 AD。
- **iptables 默认策略是 ACCEPT + 链尾 REJECT 兜底**，放行规则必须插在 REJECT 之前（`-I <行号>`，不是 `-A`）。v6 原本没有兜底，补建时要在放行规则之后。
- **ICMPv6 不是可选优化**，它承担邻居发现（等价 IPv4 的 ARP）、PMTUD、SLAAC 重复地址检测。抄 v4 的 `-p icmp` 加 REJECT 兜底可能让 IPv6 整体中断，必须显式放行 `-p ipv6-icmp`。
- **Docker 自建的 `DOCKER-*` 链不要写进持久化文件**，Docker 会自行管理，写进去会与之争抢规则。
- **旧版 OCI CLI（3.9x）**：`list` 空结果输出零字节而非 `{"data":[]}`；非空时往 stderr 打印分页 WARNING（脚本里不要用 `2>&1` 合并进结果）；`ipv6-addresses` 返回字符串列表而非字典列表；`compute image list` 必须带 `--compartment-id`；`bv boot-volume delete` 可能静默失败（rc=0 但无效），必要时改用 Python SDK。
- **Ubuntu 26.04 已上架 OCI**，但第三方软件源仍在追赶期；生产建议继续用 24.04。
- **引导卷可以热挂到运行中的实例**（`compute volume-attachment attach-paravirtualized-volume`）。实测把 106GB 引导卷只读挂到另一台运行中的 x86 读数据，全程不停机、卷上数据不变；卸载 + detach 后卷回到 `AVAILABLE`，随时可再用于开机。抢救停机实例里的数据时优先走这条路，而不是「从备份恢复新卷」（那要占新的块存储配额）。
- **抢占 ARM 容量：查询与开机是同一次调用**。`launch_instance` 失败返回 `Out of host capacity`（InternalError），成功即开机 —— 不存在「先查询有容量、再开机」的两步延迟窗口。Terraform/控制台的尝试底层也是同一次 `launch_instance` 调用，不会提高单次成功率；决定成败的是轮询间隔（脚本 200s+0~100s 抖动，实测单次调用约 3s 返回）与别人手动刷控制台拼手速。日志实例：第 1000 次尝试时仍未抢到，属正常水平。

## License

MIT
