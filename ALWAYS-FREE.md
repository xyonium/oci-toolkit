# OCI Always Free 速查（2026-11-21 核实）

> **用途**：任何 OCI 操作前先读这一页。目标只有一个 —— **操作永不产生费用**。
> **核实方式**：所有数字均来自 Oracle 官方文档/价格页原文（链接见文末），逐条标注核实日期。
> **核实日期**：2026-11-21（官方 Always Free 页面本身更新于 2026-06-12）
>
> 图例：✅ 官方已确认 ｜ ⚠️ 官方无明文（标注推理依据）｜ ❓ 未确认，不要当真

---

## ⚠️ 三条铁律（最容易踩的坑）

### 1. 只有 **home region** 里创建的资源才免费，且 A1 已砍半为 2 OCPU / 12 GB

Always Free 只在租户的 **home region** 生效；**在非 home region 创建卷会产生常规块存储费用**（官方原文："Volumes created outside of the home region incur regular block volume costs"）。三个租户的 home region 分别是 `ap-osaka-1`（JP）、`uk-london-1`（UK）、`us-phoenix-1`（ZYUSPH）——**永远不要在别的 region 建任何东西**。

ARM 额度 2026-06-15 已砍半并在官方文档确认：**1,500 OCPU-小时 + 9,000 GB-小时 / 月**（≈ 2 OCPU + 12 GB 跑满 744 小时）。**不是 4 OCPU / 24 GB。升级成 PAYG 也不恢复 4C24G**（官方只承诺"升级后 Always Free 资源仍免费"，额度本身不变）。

### 2. 存储 200 GB 是 **引导卷 + 块卷 + 备份**的硬共享配额，超了直接扣钱

200 GB 是"boot volume 与 block volume **合计**"，且**必须在 home region**。当前 **JP 和 ZYUSPH 两个租户都已 100% 用满 200 GB**：

- 再建任何一块卷（哪怕 1 GB）→ 立刻产生 `$0.0255/GB/月` 的费用
- **新建备份也算**：备份消耗的是 `backup-count`（免费 5 个），但备份的数据量同样算进 200 GB
- 实例**终止时保留引导卷** = 那块盘继续占额度（JP 那张 106 GB 孤立盘就是这么来的）

### 3. 只有"启动了的实例"才安全；"终止保留"和"预留 IP"是隐形账单

- **实例被 Oracle 回收 ≠ 免费**：实例终止后**保留下来的引导卷**照样占 200 GB 额度，占满后新卷即收费
- **预留公网 IP（Reserved Public IP）有配额（50 个/region），但 Always Free 页面从未承诺它免费** → 见下方陷阱清单，**一律用实例自带的 ephemeral IP，不要手动创建预留 IP**
- **负载均衡器**：只有"1 个 Flexible LB、10 Mbps 固定带宽"免费；把带宽调大（min 或 max ≠ 10 Mbps）立即按 `$0.0113/小时 + $0.0001/Mbps/小时` 计费

---

## 额度总表

单位为 **每租户 / 每月**，全部**仅在 home region** 有效。

| 资源 | 免费额度 | 超出计费 | 备注 |
|---|---|---|---|
| **E2.1.Micro (x86)** | **2 台**，每台 1/8 OCPU + **1 GB** 内存，50 Mbps 出网 | 无法创建第 3 台（硬上限 `standard-e2-micro-core-count` = 2） | ✅ 只需一个 AD（本处三个区均如此） |
| **A1.Flex (ARM)** | **1,500 OCPU-小时 + 9,000 GB-小时/月**（= 2 OCPU + 12 GB 跑满一月） | `$0.01/OCPU-小时`、`$0.0015/GB-小时` | ✅ 云端按**小时**计，不是固定钉死 2C12G |
| **块存储（引导+块卷）** | **200 GB 合计** | `$0.0255/GB/月` | ✅ 必须以 GB/月 计，超 1 GB 也在每月账单可见 |
| **卷备份 / 快照** | **5 个**（引导卷+块卷合计） | 第 6 个创建会**报错失败**（不是扣费） | ✅ 但备份**数据量**仍计入 200 GB |
| **对象存储** | 纯 Always Free 号：**20 GB 三档合计**；PAYG/试用号：**Standard 10 + IA 10 + Archive 10 = 30 GB** | Standard `$0.0255/GB/月`；IA `$0.01/GB/月`；Archive `$0.0026/GB/月` | ⚠️ 两档**取决于账户类型**，见下文 |
| **对象存储 API** | **50,000 请求/月** | `$0.0034 / 10,000 请求` | ✅ |
| **出站流量 (egress)** | **10 TB/月** | 北美/欧洲/UK `$0.0085/GB`；**APAC 含大阪与日本 `$0.025/GB`**；中东/非洲 `$0.05/GB` | ✅ 对个人用量等同于无限 |
| **入站流量** | **免费** | — | ✅ |
| **Load Balancer** | **1 个 Flexible，min=max=10 Mbps** | `$0.0113/小时 + $0.0001/Mbps/小时`（调大带宽即付费） | ✅ 仅 2020-12-15 后创建的租户 |
| **Network Load Balancer** | **1 个** | — | ✅ 价格页直接标 "Free" |
| **VCN** | **2 个**（非付费、非试用户） | — | ✅ 注意：**不是 10 个** |
| **Site-to-Site VPN** | **50 条 IPSec**（价格页：无端口小时费） | 流量按 egress 计 | ✅ 不需要 VPN 就别建 |
| **FastConnect** | **不在 Always Free 列表** | `$0.2125/1Gbps/端口小时` 起 | ❌ 免费层没有 |
| **自治数据库 (Autonomous AI DB)** | **2 个**，各 **1 OCPU + 20 GB**（不可扩） | 升级为付费实例后按量计费 | ✅ 20 并发会话 |
| **MySQL HeatWave** | 1 个单机标准系统，50 GB 数据 + 50 GB 备份 | — | ✅ home region |
| **NoSQL** | 1.33 亿读 + 1.33 亿写/月，3 表 × 25 GB | — | ✅ |
| **监控 (Monitoring)** | 5 亿摄取点 + 10 亿检索点 | 摄取 `$0.0025`/百万点；检索 `$0.0015`/百万点 | ✅ 个人用量难超 |
| **日志 (Logging)** | **10 GB/月**（VCN Flow Logs 共享） | `$0.05/GB/月` | ✅ **别开全量 flow log** |
| **通知 (Notifications)** | HTTPS 100 万/月 + 邮件 1,000/月 | — | ✅ |
| **邮件发送 (Email Delivery)** | 官方 Always Free 页：**3,000 封/月** | `$0.085/1,000 封` | ⚠️ **宣传页写 100 封/天**，以保守值（100/天）为准 |
| **APM** | 1,000 追踪事件 + 10 次合成监控/小时 | — | ✅ |
| **Vault** | 软件密钥全免；HSM 密钥版本 20 个；Secret 150 个 | HSM 密钥 `$0.5334/版本/月` | ✅ **Virtual Private Vault 不在免费内**（`$3.724/小时`！） |
| **Bastion** | **免费**（最多 5 个/region） | — | ✅ 价格页标 "Free" |
| **证书 (Certificates)** | **5 个私有 CA + 150 张证书** | — | ✅ 注意：这是**私有** CA，不是公信证书 |
| **DNS 解析 (权威 Zone)** | Always Free 页面**未列出** | 价格页只有"`$0.85/百万次查询`（DNS Traffic Management）" | ❓ **未确认是否免费，按"会收费"处理** |
| **Console Dashboards** | 100 个 | — | ✅ |
| **Resource Manager** | 100 栈 / 2 并发 Job / 1 私有端点 | — | ✅ |

---

## 逐条回答（A–F）

### A. 计算资源

**1. Ampere A1 到底给多少？砍半确认了吗？配额是固定数还是小时数？**

- ✅ **已确认砍半**。官方原文："All tenancies get the first **1,500 OCPU hours and 9,000 GB hours per month** for free ... For Always Free tenancies, this is equivalent to **2 OCPUs and 12 GB** of memory."
- ✅ **配额本质是"小时数"，不是钉死的 2C12G**。2 OCPU × 744 h = 1,488 ≤ 1,500；12 GB × 744 h = 8,928 ≤ 9,000。所以"2 OCPU/12 GB 跑满整月"刚好卡在线上，这就是文档把它等价于 2C12G 的原因。
- ⚠️ **推论（官方未明说）**：因为是小时额度，**让实例停止（或终止）会释放额度** —— 理论上一台 2C12G 跑半个月 + 另一台跑半个月仍可免费。但官方没说允许"轮换"，**实操上不要依赖**，按"最多 2 OCPU/12 GB 常驻"规划。
- ✅ **可拆分为 2 台 1 OCPU 的实例**（"create up to two instances of 1 OCPU each (2 OCPUs total)"），也允许只占一部分（如 1 OCPU/6 GB）。
- ✅ A1 内存下限：flexible shape 规则 "1 GB 或 ≥ OCPU 数，取较大者"。
- ❌ **4 OCPU/24 GB 已不可用**（2026-06-15 生效）。若试用期结束时超额，官方原文："all existing Ampere A1 instances are disabled and then deleted after 30 days unless you upgrade to a paid account"。

**2. E2.1.Micro (x86)：几台？多少 OCPU/内存？**
✅ **2 台**。每台 **1/8 OCPU**（"1/8th of an OCPU with the ability to use additional CPU resources"，即可突发）、**1 GB 内存**、1 个 VNIC + 1 个公网 IP、50 Mbps 出网（同区内/私网可达 480 Mbps）。
⚠️ 注意：E2.1.Micro **只能在一个 AD 内创建**（官方原文 "can only be created in one availability domain"）—— 三个租户实测都符合（JP=AD-1，UK=AD-2，ZYUSPH=PHX-AD-3）。

**3. 能否混用？比如 2 台 Micro + 1 台 A1？**
✅ **能**。官方原文明确举例："you could provision **two instances using the VM.Standard.E2.1.Micro shape, and one OCI Ampere A1 Compute instance with 2 OCPUs**（or two A1 instances with 1 OCPU each）"。Micro 配额和 A1 配额是两套独立的限额，互不挤占。
**唯一约束是 200 GB 存储**：2 台 Micro 默认各 50 GB + A1 100 GB = 200 GB，正好用满（这正是 ZYUSPH 的现状）。

**4. 超出后会怎样：扣费还是实例被终止？**
分情况：

| 超额类型 | 后果 |
|---|---|
| 建第 3 台 Micro / A1 超 2 OCPU | ❌ **创建直接被拒**（`LimitExceeded`），不会扣费 |
| 试用期结束但 A1 仍 >2 OCPU/12 GB | 🛑 **实例被禁用，30 天后删除** |
| 存储超 200 GB | 💰 **扣费**（`$0.0255/GB/月`） |
| 出站流量超 10 TB | 💰 **扣费**（APAC `$0.025/GB`） |
| 空闲实例（CPU/网络 <20%，A1 另加内存 <20%，持续 7 天） | 🛑 **Oracle 可回收实例**（引导卷保留 → 继续占存储额度） |

**5. PAYG 之后 Always Free 额度还在吗？社区说保留 4C24G，官方怎么说？**
✅ **额度还在，但内容不变**。官方原文："All Oracle Cloud Infrastructure accounts (**whether free or paid**) have a set of resources that are free of charge ... for the life of the account"；以及 "Oracle doesn't charge for Always Free resources after you upgrade, and will only charge you for resource usage above the Always Free limits"。
❌ **"PAYG 保留 4 OCPU/24 GB"没有任何官方依据**，官方 A1 额度对免费号和付费号是同一个数字：1,500 OCPU-小时/9,000 GB-小时。付费号确实有**更高但需付费**的服务限额（`standard-a1-core-count` = 16），但那是**按量收费**的普通资源，不是 Always Free。
⚠️ **PAYG 还会让对象存储额度变**：付费/试用账户是 Standard 10 + IA 10 + Archive 10（分档），纯免费号是 20 GB 合计。**我们的三个租户都是纯 Always Free，适用 20 GB 合计。**

### B. 存储

**6. 块存储总共多少？引导卷 + 块卷共享吗？**
✅ **200 GB**，官方原文："a total of 200 GB ... **These amounts apply to both boot volumes and block volumes combined**"。**完全共享，且必须在 home region。**

**7. 引导卷最小尺寸？项目文档说 50 GB**
⚠️ **官方文档自相矛盾，以 50 GB 为准。**
- Always Free 页面写着 "The minimum boot volume size for each instance is **47 GB**" —— 这句话和同页其他段落（"the minimum boot volume size allowed for compute instances is **50 GB**"、"the instance automatically receives a **50 GB** boot volume"）**自相矛盾**。
- 权威来源（Block Volume 文档，更新于 2026-09-03）："the custom boot volume size must be larger than the image's default boot volume size or **50 GB**, whichever is higher"；创建块卷："between **50 GB** and 32 TB"。
- **项目实测（2026-08-29）也证实会报错**：`Requested volume size 47GB is not in the allowed range. Boot volume should be >= 50GB`。
- **结论：新建一律 ≥ 50 GB。那两块 47 GB 是 2021 年遗留值，不要照抄。**

**8. 超出 200 GB 后怎么计费？**
✅ `$0.0255 / GB / 月`（按秒计，最少 1 分钟）。**跨月按整月累计**，删卷才停止计费。
⚠️ 注意还有一项 **Block Volume Performance Units**（`$0.0017/VPU/GB/月`）：默认 Balanced 档位是 10 VPU，**但 Always Free 卷和付费号的默认卷都按 0 VPU 计**，不要手动把性能调到 "Higher Performance"/"Ultra High Performance"。

**9. 备份/快照算不算在这个额度里？**
✅ **两套额度，容易混淆**：
- **个数**：Always Free **5 个卷备份**（引导卷 + 块卷合计），第 6 个**直接报错**，不扣费。
- **数据量**：备份数据同样计入 **200 GB**。官方只有删除卷来腾空间的建议，没有任何"备份不计入 200 GB"的说明。
⚠️ **推论**：200 GB 已满时建备份，要么失败，要么把总量顶到 200 GB 以上产生 `$0.0255/GB/月` 费用。**JP/ZYUSPH 满额状态下，不要建备份。**
⚠️ 另外：**备份策略（backup policy）会自动建备份**，一旦挂上就可能在你不注意时产生第 6 个备份或超额数据量 —— **不要给 Always Free 卷挂备份策略。**

**10. 对象存储给多少？**
✅ 取决于账户类型：
- **纯 Always Free 号（我们这三个都是）**：**20 GB**（Standard + Infrequent Access + Archive **合计**，不分档）+ 50,000 请求/月。
- **PAYG 或试用期号**：Standard **10 GB** + IA **10 GB** + Archive **10 GB**（分档，合计 30 GB）+ 50,000 请求/月。
⚠️ **陷阱**：Archive 对象被 restore 后会**回到 Standard 档并按 Standard 计费**；IA 有 **31 天**最低存储期、Archive 有 **90 天**最低存储期，**提前删除按满期收费**。

### C. 网络

**11. 出站流量免费多少？超出怎么计费？**
✅ **10 TB/月**（每个区域组各自计算）。超出后按**流量来源地区**计价：
- 北美 / 欧洲 / UK（含 Phoenix、London）：`$0.0085/GB`
- **APAC 含日本（大阪）：`$0.025/GB`** ← 我们的 JP 租户在这个档
- 中东 / 非洲：`$0.05/GB`

**12. 入站流量收费吗？**
✅ **免费**。价格页明确 "Inbound Data Transfer — Free"。流量**计在目标侧（destination region）**。

**13. 保留但未使用的公网 IP 收费吗？（经典陷阱）**
❓ **官方没有明文说 Always Free 账号免收预留 IP 费，按"会收费"处理。**
- ✅ **能查到的事实**：Reserved Public IP 的限额是 **50 个/region**（免费号与付费号相同），Ephemeral IP 限额是 **2 个/VM**。
- ✅ **能查到的事实**：Always Free 页面**完全没有提到预留公网 IP 免费**（它只提到 "Includes one VNIC with one public IP address" 属于实例自带）。
- ⚠️ **推论**：一个"未绑定到任何实例"的 Reserved Public IP 是纯静态占用，**没有任何理由免费**。第三方指南（非官方）也确认 "A reserved public IP keeps billing whether or not it is attached to a resource"。
- 🔒 **操作规则：绝不手动创建 Reserved Public IP。** 一律用实例启动时自动分配的 **Ephemeral IP**。若曾在 Console 点过 "Reserve Public IP"，**立刻删除**（`oci network public-ip delete`）。

**14. 负载均衡器：免费层给吗？给几个？**
✅ **1 个 Flexible Load Balancer，min = max = 10 Mbps**（仅 2020-12-15 之后创建的租户）。另有 **1 个 Network Load Balancer**（免费）。
⚠️ **调大带宽立刻收费**：`Load Balancer Base $0.0113/小时` + `Bandwidth $0.0001/Mbps/小时`。**只改 listeners/backend sets 没事，改带宽就会扣钱。**
⚠️ 注意付费号才有 `Load Balancer Count = 3` 的**配额**（那是可建的位数，不是免费的位）。

**15. VPN / FastConnect 免费层有吗？**
- ✅ **Site-to-Site VPN 有**：官方 "Use up to **50 IPSec connections** with your Free Tier account"；价格页 "Site-to-Site VPN is a free service with no port hour charges"（流量按 egress 计）。⚠️ 但服务限额表里 IPSec 连接默认 **4 条/region** —— 50 与 4 的差异官方未解释，**如需申请提额，提额不等于免费，慎用**。
- ❌ **FastConnect 不在 Always Free 列表**（付费：`$0.2125/1 Gbps/端口小时` 起）。

### D. 其他

**16. 自治数据库给几个？多大？**
✅ **2 个** Autonomous AI Database，每个 **1 OCPU + 20 GB 存储**（均不可缩放）、最多 20 并发会话、Serverless Exadata。✅ 必须在 home region，且该 home region 必须支持 Always Free 自治库。

**17. 监控/日志/告警免费额度？**
- ✅ **Monitoring**：5 亿摄取点 + 10 亿检索点（超额 `$0.0025`/百万点摄取、`$0.0015`/百万点检索）
- ✅ **Logging**：**10 GB/月**（超额 `$0.05/GB/月`）——**VCN Flow Logs 记在这 10 GB 里**
- ✅ **Notifications**：HTTPS 100 万/月 + 邮件 1,000/月
- ✅ **APM**：1,000 追踪事件 + 10 次合成监控/小时
⚠️ **陷阱**：开 VCN Flow Log 全面记录，可在一周内吃满 10 GB。**只在排查问题时临时开。**

**18. DNS / 证书免费吗？**
- ❓ **DNS（权威 Zone 托管）**：Always Free 页面**没有列出**。价格页只给出 DNS Traffic Management `$0.85/百万次查询`。**按"会收费"处理，不要用 OCI 做 DNS 托管**（项目本来就用 Cloudflare，无需改动）。
- ✅ **Certificates**：**5 个私有 CA + 150 张私有证书**免费。⚠️ 这是**私有 TLS 证书**，**不是公网可信证书**，别指望用它给网站签证书。

### E. 计费陷阱（最重要）

**19. 哪些操作会导致意外扣费？（穷举）**

| # | 陷阱 | 后果 | 防护 |
|---|---|---|---|
| 1 | **存储超 200 GB**（建新卷 / 扩卷 / 建备份） | `$0.0255/GB/月` | JP、ZYUSPH 已满，**任何新卷一律拒绝** |
| 2 | **实例终止后保留引导卷** | 占用 200 GB 额度 | 终止实例时**勾选删除引导卷**（除非确需保留，那就必须同时腾出等价空间） |
| 3 | **非 home region 建资源** | 全额计费 | 只动 home region；Console 右上角 region 每次都核对 |
| 4 | **备份策略自动建备份** | 占数据量 / 超 5 个 | **不要给卷挂 backup policy** |
| 5 | **手动创建 Reserved Public IP** | 未绑定仍计费 | **只用 Ephemeral IP**；发现预留 IP 立刻删 |
| 6 | **负载均衡器调大带宽** | `$0.0113/h + $0.0001/Mbps/h` | 带宽固定 10 Mbps，只改规则 |
| 7 | **A1 超 2 OCPU / 12 GB** | 试用期后实例被删；PAYG 则扣费 | 开 ARM 前先 `list` 现有 A1 总量 |
| 8 | **出站流量超 10 TB** | APAC `$0.025/GB` | 个人量级不可能触发；但别做公网大文件镜像站 |
| 9 | **VCN Flow Log 全量开启** | `$0.05/GB/月` | 临时开、用完关 |
| 10 | **IA / Archive 提前删除**（31 / 90 天最低期） | 按满期收费 | 上传前想清楚存储档 |
| 11 | **Archive 对象 restore** | 恢复后按 Standard 档计费 | 少用 Archive，或 restore 后尽快用完 |
| 12 | **Virtual Private Vault** | `$3.724/小时` | 只用普通 Vault，**绝不建 Virtual Private Vault** |
| 13 | **HSM 密钥版本 > 20 / Secret > 150** | `$0.5334/版本/月` | 软件保护密钥全免，**用软件密钥** |
| 14 | **块卷性能调档（VPU）** | `$0.0017/VPU/GB/月` | 保持默认 Balanced/0 VPU |
| 15 | **第 2 个 VCN**（免费号上限 2） | 第 3 个创建失败 | 复用 default VCN |
| 16 | **跨 region 传数据** | 目标 region 的 egress | 不做跨 region 复制 |
| 17 | **创建容量预留（Capacity Reservation）** | 付费号才可按量计费 | Free Tier 不支持，别碰 |
| 18 | **误点 "Upgrade" 转 PAYG** | 从此超出即真扣费 | **绝不点 Upgrade** |

**关于"实例规格超出免费层"**：在纯 Always Free 账号里，建超规格实例会**直接失败**（限额墙），不是悄悄计费。真正的风险是**升级 PAYG 之后**——那时限额墙变成 16 OCPU，超额就真扣钱。**所以只要不升级，"规格"这一项基本安全。**

**20. 如何查询当前用量和是否会产生费用？**

**控制台路径（最可靠，先看这个）**
1. **免费额度与已用量**：`导航菜单 → Governance & Administration → Tenancy Management → Limits, Quotas and Usage`（官方给出的路径）。筛选 `Compute` / `Block Volume`，看 `standard-a1-core-count`、`standard-e2-micro-core-count`、`Block Volumes aggregated size` 的 **Used / Available**。
2. **是否在花钱**：`导航菜单 → Billing & Cost Management → Cost Analysis`，按 `Service` 分组，**金额列只要全是 0 就安全**。
3. **账户类型**：Console 顶部如果出现 "You are using a Free Tier account..." 横幅，说明还是纯免费号（没有付费能力 = 想扣费也扣不了）。

**OCI CLI（只读查询，三个 profile 都要跑）**

```bash
# 0) 确认每个租户的 home region（Always Free 只在这里生效）
for P in DEFAULT UK ZYUSPH; do
  echo "== $P =="
  oci iam region-subscription list --profile "$P" \
    --query 'data[?`"is-home-region"`==`true`].{region:`"region-name"`, key:key}' --output table
done

# 1) 存储：所有引导卷体积合计（必须 ≤ 200，单位 GB）
for P in DEFAULT UK ZYUSPH; do
  echo -n "$P boot volumes total GB: "
  oci bv boot-volume list --profile "$P" --compartment-id \
    "$(oci iam compartment list --profile "$P" --compartment-id-in-subtree true \
       --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)" \
    --all --query 'data[?`"lifecycle-state"`!=`"TERMINATED"` && `"lifecycle-state"`!=`"TERMINATING"`]."size-in-gbs"' \
    --raw-output 2>/dev/null | tr -d '[] ' | tr ',' '\n' \
    | awk '{s+=$1} END{printf "%.0f\n", s+0}'
done

# 2) 存储：所有块卷（数据卷）体积合计
for P in DEFAULT UK ZYUSPH; do
  echo -n "$P block volumes total GB: "
  oci bv volume list --profile "$P" --all \
    --query 'data[?`"lifecycle-state"`!=`"TERMINATED"` && `"lifecycle-state"`!=`"TERMINATING"`]."size-in-gbs"' \
    --raw-output 2>/dev/null | tr -d '[] ' | tr ',' '\n' \
    | awk '{s+=$1} END{printf "%.0f\n", s+0}'
done

# 3) 计算：A1 的 OCPU / 内存总量（必须 ≤ 2 / ≤ 12）
for P in DEFAULT UK ZYUSPH; do
  echo "== $P A1 =="
  oci compute instance list --profile "$P" --all \
    --query 'data[?`"lifecycle-state"`==`"RUNNING"` || `"lifecycle-state"`==`"STOPPED"`].{shape:shape, ocpu:`"shape-config".ocpus`, mem:`"shape-config".memory-in-gbs`}' \
    --output table 2>/dev/null | grep -E 'A1|ocpu|ocpus'
done

# 4) 网络：有没有遗留的 Reserved Public IP（应为 0 个）
for P in DEFAULT UK ZYUSPH; do
  echo -n "$P reserved public IPs: "
  oci network public-ip list --profile "$P" --scope REGION --all \
    --query 'length(data[?`"lifetime"`==`"RESERVED"`])' --raw-output 2>/dev/null || echo "查询失败"
done

# 5) 有没有创建过负载均衡器（应为 0，除非确实需要）
for P in DEFAULT UK ZYUSPH; do
  echo -n "$P load balancers: "
  oci lb load-balancer list --profile "$P" --all \
    --query 'length(data[?`"lifecycle-state"`!=`"DELETED"`])' --raw-output 2>/dev/null || echo "查询失败"
done

# 6) 备份个数（必须 ≤ 5）
for P in DEFAULT UK ZYUSPH; do
  echo -n "$P volume backups: "
  oci bv boot-volume-backup list --profile "$P" --all \
    --query 'length(data[?`"lifecycle-state"`!=`"TERMINATED"`])' --raw-output 2>/dev/null || echo "查询失败"
done

# 7) 真实账单：本月按服务汇总的金额（全是 0 才安全）
TEN=$(oci iam compartment list --profile ZYUSPH \
      --compartment-id-in-subtree true --access-level ACCESSIBLE \
      --query 'data[0]."compartment-id"' --raw-output)  # 根 compartment (compartmentIdInSubtree)
TEN=${TEN:-<粘贴你的 tenancy OCID>}
S=$(date -u +%Y-%m-01T00:00:00Z); E=$(date -u +%Y-%m-%dT%H:%M:%SZ)
oci usage-api usage-summary request-summarized-usages --profile ZYUSPH \
  --tenant-id "$TEN" --granularity MONTHLY \
  --time-usage-started "$S" --time-usage-ended "$E" \
  --query-type COST --group-by '["service"]' --output table
```

> ⚠️ `oci usage-api` 返回的是**已结算数据，通常滞后 1~2 天**；`Cost Analysis` 控制台可能更实时。**两者都要看。**

**21. 有没有预算告警？怎么设？**
✅ **有，但必须知道它救不了急。**

**控制台路径**：`导航菜单 → Billing & Cost Management → Budgets → Create Budget`，范围选 **Compartment（选 root）**，类型 **Monthly**，金额填 **1**（最低值是 1），然后在 **Budget Alert Rule** 里加两条：
- `Actual Spend`，`Absolute Amount` = **0.01**（花了 1 分钱就告警）
- `Forecast Spend`，`Absolute Amount` = **1**

填上邮箱收件人，Create。

```bash
# CLI 等价操作
oci budgets budget create --profile ZYUSPH \
  --compartment-id "$TEN" --display-name always-free-guard \
  --amount 1 --reset-period MONTHLY --target-type COMPARTMENT --targets "[\"$TEN\"]"
# 再造一条告警规则（把 BUDGET_ID 换成上一步返回的 id）
oci budgets alert-rule create --profile ZYUSPH --budget-id "$BUDGET_ID" \
  --display-name spend-any --type ACTUAL \
  --threshold 0.01 --threshold-type ABSOLUTE \
  --recipients me@example.com
```

> ⚠️ **官方明确：告警每 24 小时才评估一次**（"All budget alerts are evaluated periodically every 24 hours"），且 `Forecast Spend` 需要至少 3 天数据才触发。
> **所以预算告警是"事后通知"，不是"事前拦截"。** 真正的防线是上面的额度核对 + 这份清单。
> 💡 **另外**：预算告警本身免费，但 **Notifications 邮件有 1,000 封/月免费额度**，告警很频繁的话留意。

---

## 各租户现状核对

三个租户均为**纯 Always Free 号**（未升级 PAYG），免费名额各自独立计算。

### 核对结论

| 租户 | home region | 存储用量 | 存储状态 | A1 状态 | Micro 状态 | 综合结论 |
|---|---|---|---|---|---|---|
| **DEFAULT (JP)** | `ap-osaka-1` | 47 + 47 + 106 = **200 GB** | 🔴 **100% 用满** | 0 OCPU（实例已被回收，盘还在） | 2 台 ✅ | ⚠️ **安全但不留余地**：任何新卷/备份都会扣费 |
| **UK** | `uk-london-1` | 50 + 50 = **100 GB** | 🟢 **50% 用，剩 100 GB** | 0 OCPU（**额度未用，可抢**） | 2 台 ✅ | ✅ **安全，有 100 GB 余量 + 完整 A1 额度** |
| **ZYUSPH** | `us-phoenix-1` | 50 + 50 + 100 = **200 GB** | 🔴 **100% 用满** | 2 OCPU / 12 GB ✅ | 2 台 ✅ | ⚠️ **安全但已到顶**：存储、A1 双双满额 |

**总体：三个租户当前配置全部在免费额度内，没有超额，没有产生费用。** 风险点只在 JP、ZYUSPH 的存储已用满。

### 逐条核对

**22. 这些配置都在免费额度内吗？有没有超额？**

✅ **全部在额度内，无超额。** 逐项对照：

| 项目 | JP | UK | ZYUSPH | 免费上限 |
|---|---|---|---|---|
| E2.1.Micro 台数 | 2 | 2 | 2 | 2 ✅ |
| A1 OCPU | 0 | 0 | 2 | 2 ✅ |
| A1 内存 (GB) | 0 | 0 | 12 | 12 ✅ |
| 卷存储 (GB) | 200 | 100 | 200 | 200 ✅ |
| 卷个数 | 3 | 2 | 3 | 无个数限制（只限总量）|
| home region 内 | ✅ | ✅ | ✅ | 必须 ✅ |

⚠️ **但注意两个"满额"状态**：JP 和 ZYUSPH 的 200 GB 都是**恰好卡在 100%**。这不算超额，但**再增加 1 GB 就立刻开始计费**。

**23. JP 的「3 块引导卷共 200 GB」是否正好用满？再加一块会扣费吗？**

✅ **正好用满**（47 + 47 + 106 = 200 GB）。
💰 **再加一块会扣费 —— 而且是从创建那一刻起就扣。** 一块 50 GB 的引导卷 = `50 × $0.0255` = **$1.275/月**（约 ¥9/月）。哪怕你 1 小时后删掉，也会按秒折算出几厘钱，账单上会出现非零金额。

**JP 的特殊风险**：那 106 GB 卷是 A1 实例被回收后**孤立保留**的引导卷。它的用途是给 `launch-from-bv.sh` 重新开机用 —— **这 106 GB 是"占着茅坑"的**。如果哪天决定不再重开 ARM，**删掉它就能立刻释放 106 GB**（可再开 2 台机器）。

**24. ZYUSPH 的「50+50+100 = 200 GB」是否正好用满？**

✅ **正好用满，1 GB 不差。**
这也是**当前唯一同时用满计算和存储额度的租户** —— 2 Micro + 1 A1(2C/12G) + 200 GB，**就是官方文档描述的理论最大配置**（"two instances using the VM.Standard.E2.1.Micro shape, and one OCI Ampere A1 Compute instance with 2 OCPUs"）。
⚠️ **这个租户已经不可能再加任何东西了**：加算力没有 A1 额度，加存储没有容量。**任何"扩容"念头 = 升级 PAYG = 开始花钱。**

**25. UK 只用 100 GB 还有 100 GB 余量 —— 能再加机器吗？加什么规格？**

✅ **能，而且余量很舒服。** UK 是三个租户里唯一还有腾挪空间的。

**推荐方案（50 GB 盘 + 2 OCPU/12 GB A1）：**

| 项目 | 值 |
|---|---|
| shape | `VM.Standard.A1.Flex` |
| OCPU / 内存 | **2 / 12 GB**（一次性用满 A1 额度） |
| 引导卷 | **50 GB**（新建最小值） |
| 存储合计 | 50 + 50 + 50 = **150 GB**，仍剩 **50 GB** |
| 结论 | ✅ **完全免费** |

**备选方案（100 GB 盘 + 2 OCPU/12 GB A1）：**

| 项目 | 值 |
|---|---|
| 引导卷 | **100 GB** |
| 存储合计 | 50 + 50 + 100 = **200 GB**（正好用满） |
| 结论 | ✅ **免费，但用完最后 1 GB 余量，从此归零** |

**还能不能加更多？** ❌ **Micro 不行**（已 2 台，硬上限）。理论上 A1 可拆成 2 台 1 OCPU/6 GB，但那样每台只有 1 OCPU，且仍占 2×50 GB = 100 GB —— **不如 1 台 2C12G 划算**。

💡 **建议**：UK 选 **50 GB 盘**方案，保留 50 GB 余量给未来（备份、日志、换盘）留活路。项目里 UK 的 ARM 轮询服务（`oci-uk-arm`）config 已是 `OCPUS=1 / MEMORY_GB=6` 先抢再扩容，**抢到后要记得扩到 2C/12G 并把盘控制在 50 GB**。

---

## 操作前检查清单

**每次动 OCI 之前，逐条打勾。**

- [ ] **region 是 home region 吗？** JP=`ap-osaka-1`，UK=`uk-london-1`，ZYUSPH=`us-phoenix-1`。Console 右上角每次核对。
- [ ] **账户还要不要保持纯 Always Free？** 是 → **绝不点 Upgrade**。
- [ ] **要建卷吗？** 先算：`当前总 GB + 新卷 GB ≤ 200`？
  - JP 当前 200 → **任何新卷都拒绝**
  - ZYUSPH 当前 200 → **任何新卷都拒绝**
  - UK 当前 100 → 最多再加 100 GB
- [ ] **新建引导卷 ≥ 50 GB？** 47 GB 会被拒（报错文案见 B7）。
- [ ] **要终止实例吗？** 决定好引导卷去留：
  - 保留 → 它继续占额度，必须确认总量仍 ≤ 200
  - 删除 → 勾选 "Permanently delete the attached boot volume"
- [ ] **要建备份吗？** 当前备份数 < 5 吗？加上备份数据量后总量 ≤ 200 GB 吗？JP/ZYUSPH 满额 → **不要建**。
- [ ] **卷上挂 backup policy 了吗？** 挂上会自动建备份 → **不要挂**。
- [ ] **要开 ARM 吗？** `现有 A1 OCPU + 新 A1 OCPU ≤ 2` 且 `内存合计 ≤ 12 GB`。
- [ ] **要建公网 IP 吗？** **只用 Ephemeral**，不建 Reserved。顺手查一下有没有历史遗留的 Reserved IP 要删。
- [ ] **要建负载均衡器吗？** 免费只 1 个，**带宽必须 min = max = 10 Mbps**，不要调。
- [ ] **要开 Logging / Flow Log 吗？** 本月已用 < 10 GB 吗？**用完记得关**。
- [ ] **要建 Vault 吗？** 只建普通 Vault，**绝不建 Virtual Private Vault**；密钥用**软件保护**，不用 HSM。
- [ ] **要建对象存储吗？** 总量 ≤ 20 GB（纯免费号）；IA 至少存 31 天、Archive 至少 90 天，否则按满期收费。
- [ ] **要跑批量脚本吗？** 确认脚本里没有 `--region` 覆盖、没有创建 Reserved IP / LB 的步骤。

**每日 / 每周巡检（3 分钟）**

- [ ] Cost Analysis：本月金额**是否全为 0**
- [ ] 三个 profile 的存储合计仍 ≤ 200 GB
- [ ] A1 总量 ≤ 2 OCPU / 12 GB
- [ ] Reserved Public IP 数量 = 0

---

## 官方来源

| # | 来源 | 用于核实 | 核实日期 |
|---|---|---|---|
| 1 | [Always Free Resources（OCI 文档）](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) | A1 1,500 OCPU-h/9,000 GB-h、E2.1.Micro 2 台、200 GB、5 备份、20 GB 对象存储、LB、VCN 2 个、VPN 50 条、ADB 2 个、出站 10 TB、空闲回收规则 | 2026-11-21（页面更新 2026-06-12） |
| 2 | [OCI Free Tier 总览](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier.htm) | 升级 PAYG 后 Always Free 仍有效；超额 A1 试用后 30 天删除 | 2026-11-21（页面更新 2026-06-29） |
| 3 | [Oracle Cloud Free Tier 宣传页](https://www.oracle.com/cloud/free/) | 各服务额度一览（Email 100/天、3,000 封/月等） | 2026-11-21 |
| 4 | [Free Tier FAQ](https://www.oracle.com/cloud/free/faq/) | 付费账户同样享有 Always Free；Always Free 不可转移 | 2026-11-21 |
| 5 | [OCI Price List](https://www.oracle.com/cloud/price-list/) | 全部单价：块存储 `$0.0255`、A1 `$0.01/OCPU-h`+`$0.0015/GB-h`、出站分档、LB、FastConnect、DNS、对象存储三档、Monitoring、Logging、Vault | 2026-11-21（页面更新 2026-08-25） |
| 6 | [Limits by Service](https://docs.oracle.com/en-us/iaas/Content/General/service-limits/default.htm) | `standard-e2-micro-core-count`=2、`standard-a1-core-count`=16(付费)、Reserved Public IP 50/region、VCN 10/50、Bastion 5、Trial Block Volume 200 GB | 2026-11-21（页面更新 2026-11-19） |
| 7 | [Compute Shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm) | A1.Flex 内存下限规则（1 GB 或 ≥ OCPU 数） | 2026-11-21（页面更新 2026-08-14） |
| 8 | [Working with Boot Volumes](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/bootvolumes.htm) | 引导卷最小 **50 GB**（权威口径，覆盖 Always Free 页面的 47 GB） | 2026-11-21（页面更新 2026-09-03） |
| 9 | [Creating a Block Volume](https://docs.oracle.com/en-us/iaas/Content/Block/Tasks/creatingavolume.htm) | 块卷尺寸范围 **50 GB ~ 32 TB** | 2026-11-21 |
| 10 | [Object Storage Storage Tiers](https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/understandingstoragetiers.htm) | IA 31 天 / Archive 90 天最低期；Archive restore 后按 Standard 计费 | 2026-11-21（页面更新 2026-09-25） |
| 11 | [Public IP Addresses](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingpublicIPs.htm) | Ephemeral 与 Reserved 的差异、生命周期 | 2026-11-21（页面更新 2026-02-03） |
| 12 | [Budgets 概述](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm) | **告警每 24 小时评估一次** | 2026-11-21（页面更新 2026-02-12） |
| 13 | [Creating a Budget](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/create-budget.htm) | 预算创建流程、CLI 语法、Actual/Forecast 阈值 | 2026-11-21（页面更新 2026-03-24） |
| 14 | [`request-summarized-usages` CLI 参考](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/usage-api/usage-summary/request-summarized-usages.html) | 用量查询命令的必填参数与 `--group-by` 取值 | 2026-11-21 |
| 15 | [Email Delivery 概述](https://docs.oracle.com/en-us/iaas/Content/Email/Concepts/overview.htm) | 试用账号 200 封/天限额 | 2026-11-21（页面更新 2026-05-27） |

---

## 明确"未确认"的条目（不要当事实用）

| 条目 | 状态 | 处理建议 |
|---|---|---|
| **Reserved Public IP 是否收费** | ❓ 官方网页无明文。能确认的只有：限额 50 个/region；Always Free 页面未把它列为免费资源 | **按收费处理，绝不创建** |
| **DNS 权威 Zone 是否免费** | ❓ Always Free 页面未列出，价格页只有 Traffic Management 计价 | **按收费处理，不用 OCI DNS** |
| **"PAYG 保留 4 C / 24 G"** | ❌ **已被官方文档否证**。A1 额度对免费号和付费号是同一个数（1,500 OCPU-h / 9,000 GB-h） | **不要再引用这个说法** |
| **A1 小时额度能否跨实例"轮换"拼凑** | ⚠️ 官方只给了小时数，未说明是否允许轮换 | 按"2 OCPU/12 GB 常驻"规划，别赌 |
| **VPN "50 条" vs 限额表 "4 条/region"** | ⚠️ 两者矛盾，官方未解释 | 不主动提额；提额≠免费 |
| **备份数据量是否计入 200 GB** | ⚠️ 官方没有"不计入"的表述，只建议删卷腾空间 | **按计入处理**（保守） |
| **Email Delivery 3,000 封/月 vs 100 封/天** | ⚠️ 同页两处数字不一致 | 按 **100 封/天**（更保守） |
| **Always Free 页面"引导卷最小 47 GB"** | ⚠️ **文档内部矛盾**，与 Block Volume 文档（50 GB）冲突 | **以 50 GB 为准**（项目实测亦证实 47 GB 会被拒） |
| **2026-06-15 为 ARM 砍半的生效日** | ⚠️ 日期来自项目记录与社区，**官方文档只给结果不给日期** | 结果可信，日期仅供参考 |

---

*本文件由 2026-11-21 的官方文档核实产生。**三个月内的文档变动请重新核对第 1 号来源**（Always Free 页面是唯一权威的额度清单）。*
