# AGENTS.md — oci-toolkit 项目指引

本文件是本仓库的项目指引，**DSH / Claude Code / 任何 AI agent 读它**。

---

# 🚨 第一优先级：永远不要产生费用

**本项目管理的三个 OCI 租户全是 Always Free（未升级 PAYG）。任何会产生费用的操作都是事故。**

## 动手前的三条铁律

### 1. 只在 home region 建东西

Always Free 只在租户的 **home region** 生效。官方原文：
> "Volumes created outside of the home region incur regular block volume costs"

| 租户 | profile | home region |
|---|---|---|
| DEFAULT (JP) | `DEFAULT` | `ap-osaka-1` |
| UK | `UK` | `uk-london-1` |
| ZYUSPH | `ZYUSPH` | `us-phoenix-1` |

**永远不要在别的 region 创建任何资源。**

### 2. ARM 额度是 1,500 OCPU-小时 + 9,000 GB-小时/月

= **2 OCPU + 12 GB** 跑满一个月。**不是 4 OCPU / 24 GB。**

2026-06-15 砍半，2026-08-18 强制执行（超额实例被自动终止）。
**升级成 PAYG 也不会恢复 4C24G** —— 官方只承诺"升级后 Always Free 资源仍免费"，额度本身不变。
社区传言"PAYG 保留 4C24G"已被官方文档否证。

### 3. 存储 200 GB 是「引导卷 + 块卷 + 备份数据量」的硬共享配额

- 超出按 **$0.0255/GB/月** 计费（50 GB 卷 = $1.275/月）
- **备份的数据量也算进 200 GB**（不只是 `backup-count` 的 5 个上限）
- **实例终止后保留的引导卷照样占额度**
- 满额租户**不要挂 backup policy**（会自动建备份）

## 各租户当前用量（2026-11-21 实测）

| 租户 | 实例 | 计算 | 引导卷 | 存储余量 |
|---|---|---|---|---|
| **DEFAULT (JP)** | 2×E2.1.Micro | 2C/2G | 47+47+**106** = **200 GB** | 🔴 **0 GB 满** |
| **UK** | 2×E2.1.Micro | 2C/2G | 50+50 = **100 GB** | 🟢 **100 GB** |
| **ZYUSPH** | 1×A1.Flex 2C/12G + 2×E2.1.Micro | 4C/14G | 100+50+50 = **200 GB** | 🔴 **0 GB 满** |

**JP 那张 106 GB 孤立盘**是 A1 实例被回收后保留的引导卷，给 `launch-from-bv.sh` 重开机用。
如果不再需要 ARM，**删掉它能立刻释放 106 GB**。

## 操作前强制检查

```bash
OCI=~/oci-arm-relaunch/venv/bin/oci    # 在 gpu 主机上
T=<tenancy-ocid>

# 存储合计（必须 ≤ 200）
$OCI bv boot-volume list --profile <P> --compartment-id "$T" --all \
  --query 'sum(data[]."size-in-gbs")' --raw-output

# 卷明细
$OCI bv boot-volume list --profile <P> --compartment-id "$T" --all \
  --query 'data[].{n:"display-name",s:"size-in-gbs",st:"lifecycle-state"}' --output table

# 实例
$OCI compute instance list --profile <P> --compartment-id "$T" --all \
  --query 'data[].{n:"display-name",shape:shape,st:"lifecycle-state"}' --output table

# 有没有遗留的 Reserved Public IP（应为 0）
$OCI network public-ip list --profile <P> --compartment-id "$T" --all --scope REGION \
  --query 'data[?."lifecycle-state"==`RESERVED`].{n:"display-name",ip:ip}' --output table
```

## 计费陷阱（穷举）

| 陷阱 | 后果 | 规避 |
|---|---|---|
| 非 home region 建卷 | 按常规价计费 | 只用 home region |
| 存储超 200 GB | $0.0255/GB/月 | 建卷前算总和 |
| 备份数据量 | 计入 200 GB | 满额租户不挂 backup policy |
| 终止后保留的引导卷 | 继续占额度 | 不用就删 |
| **Reserved Public IP** | 官方从不承诺免费 → **按收费处理** | 一律用 ephemeral IP，**绝不创建** |
| Load Balancer 带宽 ≠ 10 Mbps | 按小时 + 带宽计费 | 保持 min=max=10 Mbps |
| 出站流量 > 10 TB/月 | APAC $0.025/GB | 个人用量难超 |
| VCN > 2 个 | 计费 | 只用 default-vcn |
| Logging > 10 GB/月 | $0.05/GB | 别开全量 VCN Flow Log |
| Virtual Private Vault | **$3.724/小时！** | 不用 |
| 第 6 个备份 | 创建**报错**（不扣费） | 保持 ≤ 5 |

## 预算告警（兜底，不是主防线）

**官方原文：预算每天只评估一次（"evaluated periodically every 24 hours"）**，
Forecast 需要 3 天数据。**它是事后通知，不能拦住操作。**

设置方法见 `ALWAYS-FREE.md` 的「预算告警」章节。

**主防线是上面的「操作前强制检查」。**

## 完整速查表

额度全表（计算/存储/网络/数据库/监控/证书）、逐条官方来源、CLI 查询脚本、预算告警设置：
👉 **[`ALWAYS-FREE.md`](ALWAYS-FREE.md)**（2026-11-21 核实，15 个官方来源）

---

# 项目结构

```
oci-toolkit/
├── ALWAYS-FREE.md         # ⭐ OCI 免费额度速查（动手前必读）
├── README.md              # 项目说明 + 脚本清单
├── launch-from-bv.sh      # 基于已有引导卷重开 ARM 实例（引导卷复活）
├── launch-vm.sh           # 按最新 LTS 镜像开机（x86 即时 / ARM 多 AD 轮询）
├── setup-vcn.sh           # 幂等补齐 VCN 的网络缺口（IGW / 路由 / 安全列表）
├── init-iptables.sh       # iptables 放行规则迁移（v4+v6 对称，幂等，默认 dry-run）
├── gather-iptables.sh     # 采集多台主机 iptables 用于对比
├── optimize-oracle-vps.sh # Micro 系统优化（journald/swappiness/mask/swapfile）
├── setup-podman.sh        # Podman 环境标准化（fail-fast + 幂等）
├── check-arm.sh           # 一条命令看 JP/UK/ZYUSPH 三个 ARM 轮询状态
└── docs/                  # 本地文档（gitignored）
    └── project-memory.md  # 项目记忆：租户/凭据/历史决策
```

# 环境

- **OCI CLI 不在本机**（`/home/eli/cloud/oci-toolkit`），在 **gpu 主机**：`eli@gpu`
  - 路径 `~/oci-arm-relaunch/venv/bin/oci`（版本 3.91.0）
  - 凭据 `~/.oci/config`，3 个 profile：`DEFAULT` / `UK` / `ZYUSPH`
  - **`oci` 不在 gpu 非登录 shell 的 PATH 里**，必须用绝对路径或 `export PATH`
- 本机是 DSH 工作区，通过 `ssh eli@gpu` 操作 OCI

# 项目纪律

1. **凭据绝不打印**：tenancy OCID、private key、fingerprint、Telegram token 都不能出现在对话/提交里。
   `.env` 已 gitignore，`docs/` 整个目录已 gitignore。
2. **`.env.example` 里的真实 OCID 必须替换成占位符**再提交（曾因此重写过 git 历史）。
3. **改脚本前先 dry-run**：`launch-*.sh` / `setup-*.sh` / `init-iptables.sh` 都支持 `--dry-run`。
4. **提交保持小而单一**，改完同步更新 README。
5. **任何涉及创建资源（卷/实例/IP/LB）的操作，先在 `ALWAYS-FREE.md` 里对照额度。**

# 公开仓库注意

这是**公开仓库**（https://github.com/xyonium/oci-toolkit）。
推送前必须做账号指纹审查 —— 真实 OCID / 主机名 / IP / 凭据一律不能进公开提交。
