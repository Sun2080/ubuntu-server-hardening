# Changelog

所有版本变更记录。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [3.0] — 2026-03-02

### 修复
- **apply 脚本关键 Bug**：生成的 `apply-docker-configs.sh` 中 `$OUTPUT_DIR` 未定义，导致所有 `cp`/`docker cp` 命令会失败
- **MariaDB query_cache**：MariaDB 10.11+ 已完全移除 `query_cache_*` 参数，启用会导致报错
- **sysctl 不存在项**：`kernel.unprivileged_userns_clone` 在 Ubuntu 24.04 标准内核不存在，`sysctl --system` 会报错
- **PHP disable_functions 过严**：`proc_open` 导致 Composer 无法运行，`exec` 影响 WP-CLI/WordPress Cron

### 新增
- 版本追踪：`VERSION="3.0"` 写入 banner、`--help`、YAML 诊断报告
- `hosts.allow` 白名单：`hosts.deny ALL:ALL` 后自动添加 127.0.0.1 及 Docker 内网网段
- AIDE 初始化超时保护：`timeout 300` 防止在大文件系统上卡死
- 所有 `apt-get install` 添加 `--no-install-recommends` 减少攻击面

### 测试
- sec-harden.sh：18/18 (100%)
- web-optimize.sh：15/15 (100%)
- shellcheck (warning 级)：0 issue

---

## [2.0] — 2026-03-02

### 新增
- **可移植性**：Fail2ban Nginx 日志路径从硬编码改为动态检测（搜索数组 + Docker mount inspect）
- **交互确认**：`confirm_dangerous()` 函数，SSH 端口变更、UFW 启用、Docker 容器重启等危险操作即使 `--auto` 也会询问
- **`--force` 标志**：全自动无交互模式，适用于 CI/CD
- **成果反馈**：`capture_before_state()` / `show_final_summary()` 加固前→后对比表
- apply 脚本使用 `detect_host_mount()` 替代硬编码 1Panel 路径

### 修复
- Fail2ban 硬编码 1Panel 路径 → 动态自动检测（多路径搜索 + Docker mount inspect）
- cloud-init SSH 覆盖配置清理
- sysctl.conf 与 sysctl.d 优先级冲突（somaxconn）

### 测试
- sec-harden.sh：18/18 (100%)
- web-optimize.sh：15/15 (100%)

---

## [1.1] — 2026-03-02

### 修复
- 适配实际服务器环境并通过实机测试
- MariaDB buffer_pool 自动按内存比例计算
- UFW Docker 兼容规则
- dev 模式跳过 TMOUT

---

## [1.0] — 2026-03-02

### 新增
- **sec-harden.sh**：18 模块安全加固脚本
  - SSH 加固（端口/算法/prod|dev 模式）
  - UFW 防火墙 + Docker 兼容
  - Fail2ban 防暴力
  - 内核安全参数 (SYN cookies, ASLR, ptrace)
  - 内核模块黑名单
  - SUID/SGID 清理 + dpkg hook
  - 密码策略 (pwquality + faillock)
  - 文件权限加固
  - 服务精简
  - auditd 审计日志
  - 自动安全更新
  - 核心转储禁用
  - 临时目录加固
  - su 限制
  - Shell 安全 + Banner
  - AIDE 文件完整性
  - rkhunter rootkit 扫描
  - MTA 锁定

- **web-optimize.sh**：30 模块性能优化脚本
  - 内核网络调优 (BBR, TCP, somaxconn)
  - 文件描述符 + 内存策略
  - Docker 容器自动检测
  - Nginx/OpenResty 全套优化配置
  - PHP-FPM 自适应进程 + OPcache + JIT
  - MariaDB InnoDB 自适应 + 慢查询
  - Redis 自适应内存 + lazyfree
  - apply-docker-configs.sh 一键应用
  - 健康检查 / 自动清理 / OOM 防护 / Crontab

- **基础设施**
  - 完整备份 + 自动回滚脚本
  - 18 项 / 15 项验证检查
  - YAML 诊断报告
  - 交互模式 + 自动模式
