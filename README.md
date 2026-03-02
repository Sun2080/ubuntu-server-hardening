# Ubuntu Server Hardening & Web Optimization

一套面向 **Ubuntu 22.04 / 24.04 LTS** 的服务器安全加固与 Web 性能优化脚本，适用于 **1Panel + Docker** 环境。

## 功能概览

| 脚本 | 用途 | 模块数 |
|------|------|--------|
| `sec-harden.sh` | 安全加固（SSH、防火墙、内核安全、审计…） | 18 个 |
| `web-optimize.sh` | 性能优化（内核网络、Nginx、PHP、MySQL、Redis…） | 30 个 |

---

## 快速开始

### 一键下载

```bash
# 下载两个脚本
curl -fsSL https://raw.githubusercontent.com/Sun2080/ubuntu-server-hardening/main/sec-harden.sh -o sec-harden.sh
curl -fsSL https://raw.githubusercontent.com/Sun2080/ubuntu-server-hardening/main/web-optimize.sh -o web-optimize.sh

# 先加固安全，再优化性能
sudo bash sec-harden.sh
sudo bash web-optimize.sh
```

### 用法

```bash
# ========== sec-harden.sh ==========
sudo bash sec-harden.sh            # 交互模式（菜单选择）
sudo bash sec-harden.sh --auto     # 自动全量执行
SSH_MODE=dev sudo bash sec-harden.sh --auto  # 开发模式（兼容 VSCode Remote-SSH）

# ========== web-optimize.sh ==========
sudo bash web-optimize.sh            # 交互模式
sudo bash web-optimize.sh --auto     # 自动全量执行
sudo bash web-optimize.sh --dry-run  # 仅生成配置不应用系统参数
```

---

## 环境变量配置

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

### web-optimize.sh — 性能优化（30 个模块）

| 类别 | 模块 | 功能 |
|------|------|------|
| **系统** | 内核网络 | BBR、TCP 缓冲区 16M、somaxconn=65535、TIME_WAIT 优化 |
| **系统** | 文件描述符 | file-max=2M、nofile=1M、systemd 全局配置 |
| **系统** | 内存策略 | swappiness=10、dirty_ratio 优化、vfs_cache_pressure |
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
| **MySQL** | 查询 | query_cache、tmp_table_size=64M |
| **MySQL** | 慢查询 | long_query_time=1、log_not_using_indexes |
| **MySQL** | 安全 | local_infile=0、utf8mb4 |
| **Redis** | 内存 | maxmemory 自动计算、allkeys-lru |
| **Redis** | 安全 | bind 127.0.0.1、rename-command |
| **Redis** | 性能 | tcp-keepalive=300、慢日志 |
| **运维** | 配置应用 | 生成 apply-docker-configs.sh 一键应用 |
| **运维** | 健康检查 | 内存/磁盘/Docker/负载/Swap 每5分钟 |
| **运维** | 自动清理 | APT/日志/Docker/PHP session 每周日 |
| **运维** | OOM 防护 | 容器 restart + oom_score_adj 每天刷新 |

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
sec-harden.sh           # 安全加固脚本
web-optimize.sh         # 性能优化脚本
README.md               # 本文档
LICENSE                  # MIT 许可证
.gitignore              # Git 忽略规则
```

执行后生成：

```
/root/.sec-harden-backup/          # 安全加固备份 + rollback.sh
/root/.web-optimize-backup/        # 性能优化备份 + rollback.sh
/opt/server-tuning/                # 生成的优化配置
├── nginx/                         # Nginx 配置
├── php/                           # PHP-FPM 配置
├── mariadb/                       # MariaDB 配置
├── redis/                         # Redis 配置
└── apply-docker-configs.sh        # 一键应用脚本
/opt/scripts/                      # 运维脚本
├── health-check.sh                # 健康检查
├── auto-maintenance.sh            # 自动清理
└── oom-protection.sh              # OOM 防护
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
- 支持 1Panel 面板环境
- 支持 Docker 容器化 Web 服务

---

## 许可证

[MIT License](LICENSE)
