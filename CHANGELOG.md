# Changelog

所有版本变更记录。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [3.4] — 2026-03-03

### 变更
- **仓库转为公开**：移除 README 中私有仓库的 Token 认证下载方式，改为直接 `git clone` 或 `curl` 下载

---

## [3.3] — 2026-03-03

### 修复 (文档审查)
- **README 模块数虑假**：web-optimize.sh 实际包含 26 个模块（代码编号 A1–G26），README 错写为 30 个模块
- **README 幽灵模块**：模块表和文件结构中列出了 health-check.sh / auto-maintenance.sh / oom-protection.sh（`/opt/scripts/`），但实际代码并未生成这些脚本（已在早期版本中移除）
- **README 缺失模块**：代码中的 A4「禁用不必要服务」模块未在模块表中列出
- **CHANGELOG v1.0 模块数**：同步修正为 26 模块，移除幽灵条目

---

## [3.2] — 2026-03-03

### 修复 (实机测试发现)
- **VERSION 变量被 os-release 覆盖**：`check_os()` 中 `. /etc/os-release` 的 `VERSION` 变量会覆盖脚本自身的 `VERSION="3.1"`，导致 Banner 显示 `v24.04.4 LTS` 而非 `v3.1`。重命名为 `SCRIPT_VERSION`，三个脚本同步修复
- **pipefail + || echo 导致双重输出**：`set -o pipefail` 下 `$(cmd 2>/dev/null | wc -l || echo "0")` 在管道命令失败时，`wc -l` 输出 `0` 后 `|| echo "0"` 也执行，变量变成 `"0\n0"`，触发 `[[` 的 `syntax error in expression`
- **BEFORE_STATE 对比表换行错误**：`systemctl is-active` 返回 `inactive`(非零退出码) → `|| echo "未安装"` 追加输出 → 对比表中 Fail2ban/auditd 显示断行
- **SSH `Protocol 2` 废弃警告**：OpenSSH 9.x (Ubuntu 24.04) 已完全移除 Protocol 1 支持，`Protocol 2` 指令产生 Deprecated 警告，已删除
- **SSH `ChallengeResponseAuthentication` 废弃**：`KbdInteractiveAuthentication` 已是唯一正式选项，移除冗余的废弃别名

### 安全改进
- **`confirm_dangerous` 无 tty 默认值**：当 `/dev/tty` 不可用时（CI/CD、cron），默认从 `"y"` 改为 `"n"`，危险操作不再被静默批准（需显式传 `--force`）

### 优化 (web-optimize.sh)
- **`opcache.fast_shutdown`**：PHP 7.2+ 已移除此选项，改为注释说明
- **`innodb_buffer_pool_instances`**：不再硬编码为 1，当 buffer_pool ≥ 1024MB 时自动设为 8
- **`vm.overcommit_memory = 1`**：添加醒目的 OOM 风险注释
- **`docker port` pipefail 安全**：管道失败时不再追加 `"N/A"` 到正常输出
- **冗余 `2>&1` 清理**：`&>/dev/null 2>&1` → `&>/dev/null`

### 测试
- init-mirror.sh：3/3 (100%) — 腾讯云内网镜像
- sec-harden.sh：19/19 (100%) — Ubuntu 24.04 实机
- web-optimize.sh：shellcheck 零警告
- 回滚脚本验证通过

---

## [init-mirror.sh v1.0] — 2026-03-03

### 新增
- **init-mirror.sh** 独立脚本：云服务器换源 + 安全全量更新
- 自动检测云厂商（腾讯云/阿里云/华为云），通过 metadata API + 源文件推断 + DMI 信息三重检测
- 内网/外网镜像自动切换：内网可达时优先使用（延迟低、流量免费）
- Ubuntu 22.04（传统 sources.list）和 24.04（DEB822 .sources）双格式兼容
- 安全升级策略：`--force-confold` 保留现有配置文件（不覆盖 sshd_config 等）
- `NEEDRESTART_MODE=a` 自动重启服务，无交互弹窗
- Docker Hub 镜像加速：自动配置对应云厂商的 registry-mirrors
- 升级后自动 `autoremove --purge` 清理孤立包
- 内核更新后检测 `/var/run/reboot-required` 并提示重启
- 完整备份 + 回滚脚本（APT 源 + Docker daemon.json）
- 支持 `--auto`、`--force`、`MIRROR=`、`SKIP_UPGRADE=`、`DOCKER_MIRROR=` 环境变量
- shellcheck 零警告

---

## [3.1] — 2026-03-03

### 修复 (紧急 — SSH 锁死)
- **hosts.deny 锁人 Bug**：`hosts.deny ALL:ALL` 搭配的 `hosts.allow` 只加了 Docker 内网网段，忘加 `sshd: ALL`，导致所有外部 SSH 连接被 TCP wrappers 拒绝，**完全无法远程登录**
- **Ubuntu 24.04 ssh.socket 覆盖端口**：`sshd_config` 写的 `Port 2222` 被 systemd `ssh.socket`（硬编码 `ListenStream=22`）覆盖，SSH 实际监听 22 但 UFW 只放行 2222 → **端口完全错位，无法连接**
- **UFW reset 后无保护窗口**：`ufw reset` + `default deny` 之间如果脚本崩溃，SSH 会被锁死。改为 reset 后立即放行 SSH

### 新增
- SSH 模块：自动检测并覆盖 `ssh.socket` 端口（通过 systemd drop-in override）
- SSH 模块：`restart` 替代 `reload`，确保端口变更实际生效
- SSH 模块：重启后主动验证端口是否真正监听，失败立即告警
- UFW 模块：启用后验证 SSH 端口确实被放行，失败则紧急添加
- UFW 模块：reset 后立即放行当前 SSH 端口 + 目标端口（防止中途锁死）
- `hosts.allow` 中 `sshd: ALL` 放在第一行（安全由 UFW+Fail2ban 保障，TCP wrappers 不再阻断 SSH）
- 验证项新增"SSH 实际监听端口"检查（从 18 项增至 19 项）

### 测试
- sec-harden.sh：19/19 (100%)
- web-optimize.sh：15/15 (100%)

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

- **web-optimize.sh**：26 模块性能优化脚本
  - 内核网络调优 (BBR, TCP, somaxconn)
  - 文件描述符 + 内存策略 + 服务精简
  - Docker 容器自动检测
  - Nginx/OpenResty 全套优化配置
  - PHP-FPM 自适应进程 + OPcache + JIT
  - MariaDB InnoDB 自适应 + 慢查询
  - Redis 自适应内存 + lazyfree
  - apply-docker-configs.sh 一键应用

- **基础设施**
  - 完整备份 + 自动回滚脚本
  - 18 项 / 15 项验证检查
  - YAML 诊断报告
  - 交互模式 + 自动模式
