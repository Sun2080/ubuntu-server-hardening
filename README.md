# Ubuntu Server Hardening & Web Optimization

> **v3.4** | [CHANGELOG](CHANGELOG.md)

一套面向 **Ubuntu 22.04 / 24.04 LTS** 的服务器安全加固与 Web 性能优化脚本。

**特性：**
- 🔌 **开箱即用**：拉到任意 Ubuntu 服务器即可运行，自动检测环境
- 🐳 **Docker 自适应**：自动识别容器并通过 `docker inspect` 检测挂载路径
- 🛡️ **安全交互**：危险操作（改 SSH 端口、启用防火墙）即使 `--auto` 也会确认
- ⚡ **`--force` 全自动**：CI/CD 场景完全无交互
- 📊 **前后对比**：运行后显示加固前/后状态对比表 + 详细成果清单
- 🔄 **一键回滚**：每步备份，自动生成回滚脚本
- ✅ **shellcheck 零警告**：经过静态分析验证

## 功能概览

| 脚本 | 用途 | 说明 |
|------|------|------|
| `init-mirror.sh` | 换源 + 全量更新 | 自动检测云厂商，切换内网镜像，安全升级系统 |
| `sec-harden.sh` | 安全加固（18 个模块） | SSH、防火墙、内核安全、审计… |
| `web-optimize.sh` | 性能优化（26 个模块） | 内核网络、Nginx、PHP、MySQL、Redis… |

**推荐执行顺序：** `init-mirror.sh` → 安装 1Panel + Web 服务栈 → `sec-harden.sh` → `web-optimize.sh`

---

## 新服务器完整部署流程

以下是从裸机到生产就绪 Web 服务器的完整顺序：

### 阶段一：系统基础（SSH 连上就做）

```bash
# 1. 下载脚本
git clone https://github.com/Sun2080/ubuntu-server-hardening.git
cd ubuntu-server-hardening

# 2. 换源 + 系统全量更新（加速后续所有安装）
sudo bash init-mirror.sh --auto
```

### 阶段二：安装 1Panel + Web 服务栈

```bash
# 3. 安装 1Panel（会自动装 Docker）
curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh \
  -o quick_start.sh && sudo bash quick_start.sh

# 4. 补配 Docker Hub 镜像加速（1Panel 装好 Docker 后再跑一次）
#    APT 源已配好会自动跳过，仅补上 Docker 加速 + 跳过系统更新
cd ~/ubuntu-server-hardening
SKIP_UPGRADE=yes sudo bash init-mirror.sh --auto
```

登录 1Panel 面板，在「应用商店」中**依次**安装：

| 顺序 | 应用 | 说明 |
|------|------|------|
| ① | OpenResty | 反向代理 + Web 服务器 |
| ② | MySQL / MariaDB | 数据库 |
| ③ | PHP | 运行时 |
| ④ | Redis | 缓存 |
| ⑤ | phpMyAdmin（可选） | 数据库管理 |

然后在 1Panel 中创建网站、配置域名、部署代码、申请 SSL 证书。

> **为什么先装服务再加固？** `sec-harden.sh` 会自动检测 1Panel 端口放行 UFW，`web-optimize.sh` 需要检测运行中的 Docker 容器来生成配置。

### 阶段三：安全加固

> ❗ **前置要求**：先在云控制台安全组放行新 SSH 端口（默认 2222）

```bash
# 5. 执行安全加固
cd ~/ubuntu-server-hardening

# 开发/调试期间用 dev 模式（兼容 VSCode Remote-SSH）：
SSH_MODE=dev sudo bash sec-harden.sh --auto

# 纯生产服务器：
# sudo bash sec-harden.sh --auto
```

```bash
# 6. ❗ 关键：用新端口测试 SSH 连接（不要断开当前会话！）
ssh -p 2222 user@你的IP
```

### 阶段四：性能优化

```bash
# 7. 确认 SSH 新端口可连后，执行性能优化
sudo bash web-optimize.sh --auto

# 8. 审查后一键应用 Docker 容器配置
sudo bash /opt/server-tuning/apply-docker-configs.sh
```

### 完整顺序总览

```
服务器到手
  │
  ├─ ① init-mirror.sh          换源 + 系统更新
  │
  ├─ ② 安装 1Panel              自动装 Docker
  │
  ├─ ③ init-mirror.sh (再跑)   补配 Docker Hub 镜像加速
  │
  ├─ ④ 1Panel 装 Web 栈         OpenResty → MySQL → PHP → Redis
  │
  ├─ ⑤ 部署网站                 建站 + 域名 + SSL
  │
  ├─ ⑥ sec-harden.sh           安全加固（检测 1Panel 端口 + Docker）
  │
  ├─ ⑦ 验证新 SSH 端口          ⚠ 千万别断当前会话
  │
  ├─ ⑧ web-optimize.sh         性能优化（检测容器 + 生成配置）
  │
  └─ ⑨ apply-docker-configs.sh 应用容器优化配置
```

### 云安全组提前放行

在执行 `sec-harden.sh` **之前**，确保云控制台安全组已放行：

| 端口 | 用途 |
|------|------|
| `2222/tcp` | SSH 新端口（或你自定义的 `SSH_PORT`） |
| `80/tcp` | HTTP |
| `443/tcp` | HTTPS |
| 1Panel 端口 | 1Panel 面板（安装时会告诉你端口号） |

---

## 快速开始

### 一键下载

```bash
# 方式一：Git 克隆（推荐）
git clone https://github.com/Sun2080/ubuntu-server-hardening.git
cd ubuntu-server-hardening

# 方式二：仅下载脚本（无需安装 Git）
for f in init-mirror.sh sec-harden.sh web-optimize.sh; do
  curl -fsSL \
    "https://raw.githubusercontent.com/Sun2080/ubuntu-server-hardening/main/$f" \
    -o "$f"
done
```

### 用法

```bash
# ========== init-mirror.sh ==========
sudo bash init-mirror.sh                  # 交互模式（选择云厂商）
sudo bash init-mirror.sh --auto           # 自动检测云厂商 + 确认
sudo bash init-mirror.sh --auto --force   # 全自动无交互
MIRROR=aliyun sudo bash init-mirror.sh    # 指定阿里云镜像
SKIP_UPGRADE=yes sudo bash init-mirror.sh # 仅换源不升级

# ========== sec-harden.sh ==========
sudo bash sec-harden.sh                  # 交互模式（菜单选择）
sudo bash sec-harden.sh --auto           # 自动执行（危险操作仍需确认）
sudo bash sec-harden.sh --auto --force   # 全自动无交互
SSH_MODE=dev sudo bash sec-harden.sh --auto  # 开发模式（兼容 VSCode Remote-SSH）

# ========== web-optimize.sh ==========
sudo bash web-optimize.sh                  # 交互模式
sudo bash web-optimize.sh --auto           # 自动执行（危险操作仍需确认）
sudo bash web-optimize.sh --auto --force   # 全自动无交互
sudo bash web-optimize.sh --dry-run        # 仅生成配置不应用系统参数
```

> **`--force` 说明**：跳过所有交互确认（适用于 CI/CD 或无人值守部署），不加 `--force` 时，SSH 端口变更、UFW 启用、Docker 容器重启等危险操作会要求手动确认。

---

## 环境变量配置

### init-mirror.sh

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MIRROR` | `auto` | 镜像源：`auto`（自动检测）/ `tencent` / `aliyun` / `huawei` / `ustc` / `tuna` / `skip` |
| `SKIP_UPGRADE` | `no` | `yes` = 仅换源不升级 |
| `DOCKER_MIRROR` | `yes` | `yes` = 同时配置 Docker Hub 加速 |

支持的云厂商（自动检测内网/外网）：

| 厂商 | 内网镜像 | 外网镜像 |
|------|----------|----------|
| 腾讯云 | `mirrors.tencentyun.com` | `mirrors.cloud.tencent.com` |
| 阿里云 | `mirrors.cloud.aliyuncs.com` | `mirrors.aliyun.com` |
| 华为云 | `repo.myhuaweicloud.com` | `repo.huaweicloud.com` |
| 中科大 | `mirrors.ustc.edu.cn` | — |
| 清华 TUNA | `mirrors.tuna.tsinghua.edu.cn` | — |

### sec-harden.sh

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SSH_PORT` | `2222` | SSH 监听端口 |
| `SSH_MODE` | `prod` | SSH 模式：`prod`(禁止转发) / `dev`(允许转发，兼容 VSCode) |
| `FAIL2BAN_MAXRETRY` | `3` | Fail2ban 最大重试次数 |
| `FAIL2BAN_BANTIME` | `7200` | Fail2ban 封禁时间（秒） |
| `PASSWORD_MIN_LEN` | `12` | 密码最小长度 |
| `PASSWORD_MIN_CLASS` | `3` | 密码最少字符类别 |
| `PASSWORD_MAX_DAYS` | `90` | 密码最大有效天数 |
| `FAILLOCK_ATTEMPTS` | `5` | 登录失败锁定次数 |
| `FAILLOCK_LOCKTIME` | `900` | 锁定时间（秒） |
| `SHELL_TMOUT` | `300` | Shell 超时时间（秒） |
| `ALLOW_HTTP` | `yes` | 防火墙放行 80/443 |
| `DISABLE_IPV6` | `no` | 禁用 IPv6 |
| `DISABLE_PING` | `no` | 禁止 ICMP Ping |
| `RESTRICT_IP` | _(空)_ | 限制来源 IP，逗号分隔 |

### web-optimize.sh

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SYSCTL_SOMAXCONN` | `65535` | TCP 连接队列 |
| `SYSCTL_FILE_MAX` | `2097152` | 系统最大文件描述符 |
| `ULIMIT_NOFILE` | `1048576` | 进程最大文件描述符 |
| `SWAPPINESS` | `10` | Swap 使用倾向 |
| `NGINX_WORKER_CONNECTIONS` | `4096` | Nginx 工作连接数 |
| `NGINX_KEEPALIVE_TIMEOUT` | `30` | Keepalive 超时 |
| `NGINX_CLIENT_MAX_BODY` | `50M` | 最大请求体 |
| `NGINX_GZIP_LEVEL` | `4` | Gzip 压缩级别 |
| `PHP_PM_MODE` | `dynamic` | PHP-FPM 进程管理模式 |
| `PHP_MAX_REQUESTS` | `500` | PHP-FPM 最大请求数 |
| `PHP_OPCACHE_MEMORY` | `128` | OPcache 内存(MB) |
| `PHP_MEMORY_LIMIT` | `256M` | PHP 内存限制 |
| `PHP_UPLOAD_MAX` | `50M` | PHP 上传限制 |
| `MARIADB_MAX_CONN` | `100` | MySQL 最大连接数 |
| `MARIADB_SLOW_QUERY_TIME` | `1` | 慢查询阈值（秒） |
| `REDIS_MAXMEMORY` | _(自动)_ | Redis 最大内存 |
| `REDIS_POLICY` | `allkeys-lru` | Redis 淘汰策略 |

示例：自定义参数执行
```bash
SSH_PORT=2022 FAIL2BAN_BANTIME=3600 sudo bash sec-harden.sh --auto
SWAPPINESS=5 MARIADB_MAX_CONN=200 sudo bash web-optimize.sh --auto
```

---

## 模块说明

### sec-harden.sh — 安全加固（18 个模块）

| # | 模块 | 功能 |
|---|------|------|
| 1 | SSH 加固 | 自定义端口、禁密码登录(检测密钥)、Ed25519 优先、prod/dev 模式 |
| 2 | UFW 防火墙 | 默认拒绝入站、放行 SSH+HTTP+1Panel、支持限制来源 IP |
| 3 | Fail2ban | SSH 防暴力(3次/2h)、累犯(ban一周)、Nginx 防扫描 |
| 4 | 内核安全参数 | SYN cookies、禁 ICMP 重定向、反向路径过滤、ASLR、禁 ptrace |
| 5 | 内核模块黑名单 | 禁用 dccp/sctp/tipc/rds/cramfs/usb-storage 等 |
| 6 | SUID/SGID 清理 | 去除 chfn/chsh/mount 等 SUID、dpkg hook 防 apt 恢复 |
| 7 | 密码策略 | pwquality + faillock + login.defs + 记住5次旧密码 |
| 8 | 文件权限 | shadow/sshd_config=600、cron 目录=700 |
| 9 | 服务精简 | 禁用 avahi/cups/ModemManager、卸载 telnet/rsh |
| 10 | 审计日志 | auditd 监控 passwd/shadow/sudoers/内核模块/挂载等 |
| 11 | 自动安全更新 | unattended-upgrades 每日检查 |
| 12 | 核心转储禁用 | limits + systemd + sysctl 三重禁用 |
| 13 | 临时目录加固 | /tmp(nosuid)、/dev/shm(noexec)、/var/tmp(noexec) |
| 14 | su 限制 | 仅 sudo 组可使用 su |
| 15 | Shell 安全 | TMOUT 超时、安全别名、登录 Banner、hosts.deny |
| 16 | AIDE | 文件完整性检测 + 每日自动检查 |
| 17 | rkhunter | rootkit 检测 + 每周自动扫描 |
| 18 | MTA 锁定 | Postfix 仅监听 127.0.0.1 |

### web-optimize.sh — 性能优化（26 个模块）

| 类别 | 模块 | 功能 |
|------|------|------|
| **系统** | 内核网络 | BBR、TCP 缓冲区 16M、somaxconn=65535、TIME_WAIT 优化 |
| **系统** | 文件描述符 | file-max=2M、nofile=1M、systemd 全局配置 |
| **系统** | 内存策略 | swappiness=10、dirty_ratio 优化、vfs_cache_pressure |
| **系统** | 服务精简 | 禁用 ModemManager/upower/udisks2 释放内存 |
| **Docker** | 容器检测 | 自动识别 Nginx/PHP/MariaDB/Redis 容器 |
| **Nginx** | 主配置 | worker_processes=auto、connections=4096、sendfile+tcp_nopush |
| **Nginx** | Gzip | level=4、256 最小长度、全类型支持 |
| **Nginx** | 静态缓存 | open_file_cache、expires 配置 |
| **Nginx** | FastCGI 缓存 | 缓存路径+zone+大小+过期策略 |
| **Nginx** | 限流 | 10r/s 普通 + 3r/m 登录 + 连接数限制 |
| **Nginx** | 安全头 | X-Frame-Options、HSTS、CSP、Permissions-Policy |
| **Nginx** | 敏感拦截 | 禁 .git/.env/.sql/.bak、禁 uploads 执行 PHP |
| **Nginx** | 日志 | 含 request_time、upstream_response_time |
| **PHP** | 进程管理 | dynamic 模式、根据内存自动计算 max_children |
| **PHP** | OPcache | 128M 内存、JIT 1255、64M buffer |
| **PHP** | 安全 | expose_php=Off、disable_functions、memory_limit |
| **PHP** | Session | httponly、secure、strict_mode、samesite |
| **MySQL** | InnoDB | buffer_pool=内存20%、flush_method=O_DIRECT |
| **MySQL** | 连接 | max_connections=100、wait_timeout=600 |
| **MySQL** | 查询 | tmp_table_size=64M、join_buffer 优化 |
| **MySQL** | 慢查询 | long_query_time=1、log_not_using_indexes |
| **MySQL** | 安全 | local_infile=0、utf8mb4 |
| **Redis** | 内存 | maxmemory 自动计算、allkeys-lru |
| **Redis** | 安全 | bind 127.0.0.1、rename-command |
| **Redis** | 性能 | tcp-keepalive=300、慢日志 |
| **运维** | 配置应用 | 生成 apply-docker-configs.sh 一键应用 |

---

## 回滚

两个脚本都会自动生成回滚脚本：

```bash
# 安全加固回滚
sudo bash /root/.sec-harden-backup/<时间戳>/rollback.sh

# 性能优化回滚
sudo bash /root/.web-optimize-backup/<时间戳>/rollback.sh
```

回滚脚本会恢复所有被修改的文件到原始状态。

---

## 核心原则

- **sec-harden.sh**: 纯安全加固，不涉及性能调优
- **web-optimize.sh**: 纯性能优化，**不直接修改 Docker 容器**
  - 所有 Docker 服务配置生成到 `/opt/server-tuning/` 目录
  - 同时生成 `apply-docker-configs.sh` 供审查后一键应用
- 所有参数可通过环境变量覆盖
- 每步备份原文件、自动生成回滚脚本
- 最终验证 + YAML 诊断报告

---

## 文件结构

```
init-mirror.sh          # 换源 + 全量更新脚本 (v1.0)
sec-harden.sh           # 安全加固脚本 (v3.3)
web-optimize.sh         # 性能优化脚本 (v3.3)
README.md               # 本文档
CHANGELOG.md            # 版本变更记录
LICENSE                  # MIT 许可证
.gitignore              # Git 忽略规则
```

执行后生成：

```
/root/.init-mirror-backup/         # 换源备份 + rollback.sh
/root/.sec-harden-backup/          # 安全加固备份 + rollback.sh
/root/.web-optimize-backup/        # 性能优化备份 + rollback.sh
/opt/server-tuning/                # 生成的优化配置
├── nginx/                         # Nginx 配置
├── php/                           # PHP-FPM 配置
├── mariadb/                       # MariaDB 配置
├── redis/                         # Redis 配置
└── apply-docker-configs.sh        # 一键应用脚本
/var/log/init-mirror-*.log         # 换源日志
/var/log/sec-harden-*.log          # 安全加固日志
/var/log/web-optimize-*.log        # 性能优化日志
/var/log/sec-harden-diag-*.yaml    # 安全诊断报告
/var/log/web-optimize-diag-*.yaml  # 性能诊断报告
```

---

## 适用系统

- **Ubuntu 22.04 LTS** (Jammy Jellyfish)
- **Ubuntu 24.04 LTS** (Noble Numbat)
- 需要 root 权限
- 支持 1Panel / 宝塔 / 自定义 Docker 环境（自动检测挂载路径）
- 支持 Docker 容器化 Web 服务（Nginx/OpenResty, PHP-FPM, MariaDB/MySQL, Redis）

---

## 许可证

[MIT License](LICENSE)
