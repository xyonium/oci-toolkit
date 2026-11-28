# oci-toolkit — 甲骨文云 (OCI) 运维工具集

> ## 💰 动手前必读：[`ALWAYS-FREE.md`](ALWAYS-FREE.md)
>
> **这份文档是为了"永远不产生费用"而写的。任何 OCI 操作（建卷/开机器/改带宽/加备份）之前先看它。**
>
> 最短版本 —— 三条铁律：
>
> 1. **只在 home region 建东西**。非 home region 的卷按常规价格计费。
>    JP=`ap-osaka-1` / UK=`uk-london-1` / ZYUSPH=`us-phoenix-1`。
>    ARM 额度是 **1,500 OCPU-小时 + 9,000 GB-小时/月**（≈2 OCPU+12 GB 跑满），
>    **不是 4C24G，升级 PAYG 也不会变回来**。
> 2. **存储 200 GB 是「引导卷 + 块卷 + 备份数据量」的硬共享配额**，必须在 home region。
>    **当前 JP 和 ZYUSPH 都已 100% 用满（各 200 GB）** —— 再加任何一块卷、
>    建任何备份，立刻开始扣 `$0.0255/GB/月`。UK 用了 100 GB，还有 100 GB 余量。
> 3. **"终止保留"的引导卷照样占额度**（JP 那张 106 GB 孤立盘就是这么来的）；
>    **Reserved Public IP 官方从不承诺免费** —— 一律用实例自带的 ephemeral IP。
>
> **操作前的强制检查**（改任何 OCI 资源前跑一遍）：
>
> ```bash
> # 存储合计（必须 ≤ 200）
> oci bv boot-volume list --profile <P> --compartment-id <TENANCY> --all \
>   --query 'sum(data[]."size-in-gbs")' --raw-output
> # 有没有多余的卷 / Reserved IP / 备份
> oci bv boot-volume list --profile <P> --compartment-id <TENANCY> --all \
>   --query 'data[].{n:"display-name",s:"size-in-gbs",st:"lifecycle-state"}' --output table
> ```
>
> 完整速查表（额度全表、计费陷阱穷举、查询命令、预算告警设置）见 [`ALWAYS-FREE.md`](ALWAYS-FREE.md)。
> 该文档 2026-11-21 核实，15 个官方来源，无法确认的项已明确标注"按收费处理"。

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

### 6. `optimize-oracle-vps.sh` — E2.1.Micro (1GB) 系统级优化（幂等）

```bash
./optimize-oracle-vps.sh ubuntu@<host> [...]          # 默认 dry-run
./optimize-oracle-vps.sh ubuntu@<host> ... --apply    # 实际执行
```

优化项（详见脚本头部注释的实测根因）：oracle-cloud-agent snap 旧修订版清理；journald 上限 100M（防 `podman logs` 全量扫描数 GB 日志冲垮 Page Cache）；最小包集合（purge dlocate/dctrl-tools/supercat）；`vm.swappiness=10` + 冷 SwapCached 回收；**mask `fwupd`/`fwupd-refresh.timer`/`multipathd`**（OCI 虚拟机内无可刷写固件——固件/微码由 Oracle 宿主机侧维护，Ubuntu 官方 cloud image 亦已移除 fwupd；单路径 iSCSI 根盘无 multipath 管理对象；两者合计常驻 ~60MB，JP/UK 已跨重启验证无影响）；**创建 512MB `/swapfile` 并写入 fstab**（1GB 微机内存兜底，已挂载则跳过、fstab 缺条目则补写）；**启用 BBR + `fq`（保留 `mq` 多队列，并通过 `/usr/local/sbin/dsh-apply-fq` + `dsh-bbr-qdisc.service` 防止 Oracle 26.04 initramfs 阶段 `ens3` 留在 `pfifo_fast`）+ `tcp_mtu_probing=1`**。

### 7. `setup-podman.sh` — Podman 容器环境标准化（严格前置校验 + 幂等）

脏状态（Docker 残留链/不纯的 rules.v4/v6）一律 fail-fast 报错，绝不盲目自动拼接；通过后安装 Podman + crun + podman-compose 并固化 `00-shortnames.conf`。

### 8. `provision-oracle-node.sh` — 26.04 节点一条命令开荒（幂等）

```bash
./provision-oracle-node.sh ubuntu@<ip> --domain <域名> --wan-iface ens3 \
    --email you@example.com --apply
```

把「新机上线」固化成一条命令，按顺序跑并逐段校验：系统基线优化 → nft 主机防火墙
（`--converge-legacy --enable-oci-meta`）→ **收敛收尾**（卸 `iptables-persistent`、移走
`rules.v4/v6`、flush 内核里的旧 iptables 规则，否则后续 podman 判定会中止）→ `setup-podman.sh`
→ `setup_caddy_xray_hysteria.sh`（REALITY/WS/XHTTP + Hysteria2）→ `systemctl start nftables`
→ `verify-bootstrap.sh` 28 项验收。不加 `--apply` 即全程 dry-run。

> 顺序是踩出来的：收敛收尾必须在 podman 之前，而 `oci_meta` 又必须在收尾之前接管
> InstanceServices —— 脚本会先确认 `nft list table inet oci_meta` 里 accept ≥ 10 才动手。

### 9. `cross-region-copy.sh` — 引导卷跨区复制（规划中）

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

## 获取 OCI API 凭据（推荐网页生成）

直接在 OCI 控制台生成 API Key 即可，**不需要先运行 `oci setup config`，也不需要分别查找 User OCID、Tenancy OCID 和 fingerprint**。添加 API Key 后，控制台会自动生成包含这些字段的配置文件片段。

### 1. 在控制台生成密钥对

1. 登录 [OCI 控制台](https://cloud.oracle.com/)，进入 **右上角头像 → 用户设置 / User settings → 令牌和密钥 / Token and keys**（部分界面显示为 **API Keys**）。
2. 点击 **Add API Key**，选择 **Generate API Key Pair / 生成 API 密钥对**。
3. 按页面提示**下载私钥**；公钥可按需下载，控制台会登记与私钥对应的公钥，无需再手动上传。
4. 点击 **Add**，复制页面给出的 **Configuration File Preview / 配置文件片段**。

私钥通常只能在生成时下载，之后无法从控制台重新取回。请妥善保存，不要提交到 Git 或发给他人；如果丢失，需要重新创建 API Key。

### 2. 保存私钥并写入 config

把下载的私钥安全地放到**实际运行脚本的 Linux 主机**上，例如 `~/.oci/oci_api_key.pem`。如果私钥下载到了另一台电脑，先安全复制到这台主机。

将控制台自动生成的配置片段写入 `~/.oci/config`。首次配置使用 `[DEFAULT]`，例如：

```ini
[DEFAULT]
user=ocid1.user.oc1..网页自动生成的值
fingerprint=网页自动生成的值
tenancy=ocid1.tenancy.oc1..网页自动生成的值
region=us-phoenix-1
key_file=/home/你的用户名/.oci/oci_api_key.pem
```

`user`、`fingerprint`、`tenancy`、`region` **全部沿用网页自动生成的值**。通常只需要把 `key_file` 改为本机私钥的实际绝对路径，确保路径和 `.pem` 文件名与保存的私钥一致。

设置文件权限（私钥文件名按实际情况调整）：

```bash
mkdir -p ~/.oci
chmod 700 ~/.oci
chmod 600 ~/.oci/config
chmod 600 ~/.oci/oci_api_key.pem
```

### 3. 验证凭据

在项目目录执行只读查询：

```bash
./venv/bin/oci --profile DEFAULT --auth api_key os ns get
```

能返回 Object Storage namespace，即表示 API Key 认证和 config 均已生效。

### 多租户

凭据用 OCI CLI 的 INI 多 profile 共存，互不干扰。新增租户时，把网页生成的配置片段**追加**到现有 `~/.oci/config`，将新片段的段名从 `[DEFAULT]` 改为 `[UK]`，并让 `.env` 使用相同的 `OCI_PROFILE=UK`：

```ini
# ~/.oci/config
[DEFAULT]      # 旧租户，原有内容保持不变
[UK]           # 新租户 —— .env 里 OCI_PROFILE=UK
```

新片段中自动生成的认证字段仍然照抄，只需让 `key_file` 指向本次下载的新私钥。新私钥使用**新文件名**（如 `uk_api_key.pem`），不要覆盖旧租户的 profile 或 `.pem`。验证时将命令中的 `--profile DEFAULT` 换成 `--profile UK`。

## 需要准备的资源 OCID

以下资源参数不包含在 API Key 自动生成的认证配置中，仍需按场景填写：

| 变量 | 获取方式 |
|---|---|
| `COMPARTMENT_ID` | 控制台租户信息，或 `oci iam compartment list` |
| `BOOT_VOLUME_ID` | 存储 → 块存储 → 引导卷 → 复制 OCID（注意其可用域！） |
| `TARGET_AD` | 引导卷详情页的「可用性域」，必须与卷完全一致 |
| `SUBNET_ID` | 网络 → 虚拟云网络 → 子网 → 复制 OCID |

参考：[Oracle 官方：API Signing Key](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)。

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
├── optimize-oracle-vps.sh # E2.1.Micro 系统级优化（journald/swappiness/mask 无用服务/swapfile）
├── setup-podman.sh       # Podman 环境标准化（fail-fast 前置校验 + 幂等）
├── provision-oracle-node.sh # 26.04 节点一条命令开荒（优化/防火墙/收敛/podman/xray/验收）
├── check-arm.sh          # 一条命令查看 JP/UK/ZYUSPH/ZPUSSJ/AUMEL 五个 ARM 轮询的状态与进度
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

## 主机防火墙去哪了

`init-firewall.sh`（nft `inet dsh_firewall`，profile 切换）已移入 [vpsetup](../../vpsetup)，
因为它是「给任何一台代理节点上防火墙」，与 OCI 无关，GCP / 阿里云 / 搬瓦工 / Oracle 共用同一份。
