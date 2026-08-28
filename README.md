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

### 2. `cross-region-copy.sh` — 引导卷跨区复制（规划中）

TODO：定期把指定引导卷备份/复制到另一个区域，异地容灾。

## 快速开始

```bash
# 1. 在任意有网的 Linux 主机上
git clone https://github.com/xyonium/oci-toolkit.git
cd oci-toolkit

# 2. 安装 OCI CLI（venv 隔离，不动系统 Python）
./setup.sh            # 含 venv + oci-cli + systemd 单元 + enable-linger

# 3. 填配置
cp .env.example .env  # 把你的 OCID / AD / 规格填进去（README 下方有获取方法）

# 4. 干跑验证
./launch-from-bv.sh --dry-run

# 5. 单次真实调用验证（预期返回 Out of host capacity = 参数全对，只差容量）
./launch-from-bv.sh --once

# 6. 挂到 systemd 常驻轮询
./setup.sh enable
tail -f logs/launch.log
```

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
├── .env.example          # 配置模板（复制为 .env 使用，已被 gitignore）
├── launch-from-bv.sh     # 核心轮询脚本
├── setup.sh              # 安装 + systemd 服务管理
├── docs/                 # 设计文档
└── README.md
```

## License

MIT
