#!/usr/bin/env bash
###############################################################################
#  sec-harden.sh — Ubuntu 服务器安全加固脚本
#  适用系统: Ubuntu 22.04 / 24.04 LTS
#  用法:
#    sudo bash sec-harden.sh                  # 交互模式（菜单选择）
#    sudo bash sec-harden.sh --auto           # 自动执行（危险操作仍需确认）
#    sudo bash sec-harden.sh --auto --force   # 全自动无交互
#    SSH_MODE=dev sudo bash sec-harden.sh --auto  # 开发模式
###############################################################################
set -Euo pipefail
SCRIPT_VERSION="3.3"

# ─── ERR trap ────────────────────────────────────────────────────────────────
trap '_err_handler $LINENO "$BASH_COMMAND"' ERR
_err_handler() {
    local lineno=$1 cmd=$2
    log "ERROR" "命令失败 (行 $lineno): $cmd"
}

# ─── 全局变量（均可通过环境变量覆盖）─────────────────────────────────────────
SSH_PORT="${SSH_PORT:-2222}"
SSH_MODE="${SSH_MODE:-prod}"               # prod | dev
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-3}"
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-7200}"
PASSWORD_MIN_LEN="${PASSWORD_MIN_LEN:-12}"
PASSWORD_MIN_CLASS="${PASSWORD_MIN_CLASS:-3}"
PASSWORD_MAX_DAYS="${PASSWORD_MAX_DAYS:-90}"
FAILLOCK_ATTEMPTS="${FAILLOCK_ATTEMPTS:-5}"
FAILLOCK_LOCKTIME="${FAILLOCK_LOCKTIME:-900}"
SHELL_TMOUT="${SHELL_TMOUT:-300}"
ALLOW_HTTP="${ALLOW_HTTP:-yes}"            # yes | no
DISABLE_IPV6="${DISABLE_IPV6:-no}"         # yes | no
DISABLE_PING="${DISABLE_PING:-no}"         # yes | no
RESTRICT_IP="${RESTRICT_IP:-}"             # 限制来源 IP，逗号分隔
INSTALL_AIDE="${INSTALL_AIDE:-yes}"        # yes | no
INSTALL_RKHUNTER="${INSTALL_RKHUNTER:-yes}" # yes | no
AUTO_MODE="${AUTO_MODE:-no}"
FORCE_MODE="${FORCE_MODE:-no}"           # --force 跳过所有交互确认

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/.sec-harden-backup/${TIMESTAMP}"
ROLLBACK_SCRIPT="${BACKUP_DIR}/rollback.sh"
LOG_FILE="/var/log/sec-harden-${TIMESTAMP}.log"
DIAG_FILE="/var/log/sec-harden-diag-${TIMESTAMP}.yaml"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# ─── 颜色与输出 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() {
    local level=$1; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color="$NC"
    case "$level" in
        INFO)  color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        STEP)  color="$CYAN"   ;;
    esac
    printf '%b[%s] [%-5s] %s%b\n' "$color" "$ts" "$level" "$*" "$NC" | tee -a "$LOG_FILE"
}

step_banner() {
    local num=$1; shift
    echo "" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b  步骤 %s: %s%b\n' "${BOLD}${CYAN}" "$num" "$*" "$NC" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
}

check_result() {
    local desc=$1 result=$2
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$result" == "pass" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  %b✓%b %s\n' "${GREEN}" "${NC}" "$desc" | tee -a "$LOG_FILE"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  %b✗%b %s\n' "${RED}" "${NC}" "$desc" | tee -a "$LOG_FILE"
    fi
}

# ─── 危险操作确认（即使 --auto 也会询问，--force 跳过）────────────────────────
confirm_dangerous() {
    local msg=$1
    if [[ "$FORCE_MODE" == "yes" ]]; then
        log "INFO" "[FORCE] 跳过确认: $msg"
        return 0
    fi
    echo "" | tee -a "$LOG_FILE"
    printf '  %b⚠ 危险操作: %s%b\n' "${YELLOW}" "${NC}" "$msg" | tee -a "$LOG_FILE"
    printf '  %b确认继续? [y/N]: %b' "${BOLD}" "${NC}"
    read -r answer </dev/tty 2>/dev/null || answer="n"
    case "$answer" in
        [yY]*) return 0 ;;
        *) log "WARN" "用户取消: $msg"; return 1 ;;
    esac
}

# ─── 运行前状态快照 ──────────────────────────────────────────────────────────
declare -A BEFORE_STATE
capture_before_state() {
    # 注意: 由于 set -o pipefail，管道命令失败时 || 会额外输出，
    # 因此将 || 放在 $() 之外，避免双重输出
    BEFORE_STATE[ssh_port]=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}') || true
    [[ -z "${BEFORE_STATE[ssh_port]}" ]] && BEFORE_STATE[ssh_port]="22"
    BEFORE_STATE[ssh_pwd_auth]=$(grep -E '^PasswordAuthentication ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}') || true
    [[ -z "${BEFORE_STATE[ssh_pwd_auth]}" ]] && BEFORE_STATE[ssh_pwd_auth]="unknown"
    BEFORE_STATE[ssh_root_login]=$(grep -E '^PermitRootLogin ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}') || true
    [[ -z "${BEFORE_STATE[ssh_root_login]}" ]] && BEFORE_STATE[ssh_root_login]="unknown"
    BEFORE_STATE[ufw_status]=$(ufw status 2>/dev/null | head -1) || true
    [[ -z "${BEFORE_STATE[ufw_status]}" ]] && BEFORE_STATE[ufw_status]="未安装"
    BEFORE_STATE[fail2ban]=$(systemctl is-active fail2ban 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[fail2ban]}" || "${BEFORE_STATE[fail2ban]}" == "inactive" ]] && BEFORE_STATE[fail2ban]="未运行"
    BEFORE_STATE[syncookies]=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[syncookies]}" ]] && BEFORE_STATE[syncookies]="?"
    BEFORE_STATE[aslr]=$(sysctl -n kernel.randomize_va_space 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[aslr]}" ]] && BEFORE_STATE[aslr]="?"
    BEFORE_STATE[core_dump]=$(sysctl -n fs.suid_dumpable 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[core_dump]}" ]] && BEFORE_STATE[core_dump]="?"
    BEFORE_STATE[auditd]=$(systemctl is-active auditd 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[auditd]}" || "${BEFORE_STATE[auditd]}" == "inactive" ]] && BEFORE_STATE[auditd]="未运行"
    BEFORE_STATE[auto_update]=$(systemctl is-enabled unattended-upgrades 2>/dev/null) || true
    [[ -z "${BEFORE_STATE[auto_update]}" ]] && BEFORE_STATE[auto_update]="未启用"
    BEFORE_STATE[docker_count]=$( { docker ps -q 2>/dev/null || true; } | wc -l )
}

# ─── 前置检查 ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
        echo "用法: sudo bash $0 [--auto]"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log "ERROR" "无法检测操作系统"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log "ERROR" "此脚本仅支持 Ubuntu 系统，当前: $ID"
        exit 1
    fi
    log "INFO" "检测到 $PRETTY_NAME (内核 $(uname -r))"
}

# ─── 备份与回滚框架 ──────────────────────────────────────────────────────────
init_backup() {
    mkdir -p "$BACKUP_DIR"
    cat > "$ROLLBACK_SCRIPT" << 'ROLLBACK_HEADER'
#!/usr/bin/env bash
# 自动生成的回滚脚本
set -euo pipefail
echo "=== 开始回滚安全加固 ==="
ROLLBACK_HEADER
    chmod 700 "$ROLLBACK_SCRIPT"
    log "INFO" "备份目录: $BACKUP_DIR"
}

backup_file() {
    local src=$1
    if [[ -f "$src" ]]; then
        local dest="${BACKUP_DIR}${src}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$src" "$dest"
        # 在回滚脚本中添加恢复命令
        echo "cp -a '${dest}' '${src}' && echo '已恢复: ${src}'" >> "$ROLLBACK_SCRIPT"
    fi
}

# ─── 自动检测 1Panel 端口 ────────────────────────────────────────────────────
detect_1panel_ports() {
    local ports=()
    # 检测 1Panel Core 端口
    local core_port
    core_port=$(ss -tlnp 2>/dev/null | grep '1panel-core\|1panel' | awk '{print $4}' | grep -oP '\d+$' | head -1 || true)
    if [[ -z "$core_port" ]]; then
        # 尝试从进程命令行获取
        core_port=$(ss -tlnp 2>/dev/null | grep -oP '0\.0\.0\.0:(\d{4,5})' | grep -oP '\d+' | while read -r p; do
            if ss -tlnp "sport = :$p" 2>/dev/null | grep -q '1panel'; then echo "$p"; fi
        done | head -1 || true)
    fi
    # 回退到常见端口
    if [[ -z "$core_port" ]]; then
        for p in 62828 8888 9999; do
            if ss -tlnp "sport = :$p" 2>/dev/null | grep -q 'LISTEN'; then
                core_port=$p
                break
            fi
        done
    fi
    [[ -n "$core_port" ]] && ports+=("$core_port")

    # 检测 1Panel Agent 端口 (通常 core_port + 1 或 9999)
    local agent_port
    agent_port=$(ss -tlnp 2>/dev/null | grep '1panel-agent' | awk '{print $4}' | grep -oP '\d+$' | head -1 || true)
    if [[ -z "$agent_port" && -n "$core_port" ]]; then
        local try_port=$((core_port + 1))
        if ss -tlnp "sport = :$try_port" 2>/dev/null | grep -q 'LISTEN'; then
            agent_port=$try_port
        fi
    fi
    [[ -n "$agent_port" ]] && ports+=("$agent_port")

    echo "${ports[*]:-}"
}

###############################################################################
#  模块 1: SSH 加固
###############################################################################
harden_ssh() {
    step_banner 1 "SSH 加固"
    local sshd_conf="/etc/ssh/sshd_config"

    # 危险操作确认: SSH 端口更改
    local cur_port
    cur_port=$(grep -E '^Port ' "$sshd_conf" 2>/dev/null | awk '{print $2}' || echo "22")
    [[ -z "$cur_port" ]] && cur_port="22"
    if [[ "$cur_port" != "$SSH_PORT" ]]; then
        if ! confirm_dangerous "SSH 端口将从 $cur_port 更改为 $SSH_PORT (请确保云安全组/防火墙已放行新端口)"; then
            log "WARN" "跳过 SSH 端口更改"
            SSH_PORT="$cur_port"  # 保持原端口
        fi
    fi

    backup_file "$sshd_conf"

    # 备份 sshd_config.d 下的文件
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] && backup_file "$f"
        done
    fi

    # 检测是否有 SSH 密钥
    local has_keys=false
    for user_home in /root /home/*; do
        if [[ -f "${user_home}/.ssh/authorized_keys" ]] && [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
            has_keys=true
            break
        fi
    done

    log "INFO" "SSH 端口设置为: $SSH_PORT"
    log "INFO" "SSH 模式: $SSH_MODE"
    log "INFO" "检测到 SSH 密钥: $has_keys"

    # 构建配置
    local ssh_config=""
    ssh_config+="# === sec-harden.sh 安全加固配置 $(date +%F) ===\n"
    ssh_config+="Port ${SSH_PORT}\n"
    ssh_config+="AddressFamily inet\n"
    ssh_config+="\n# 认证\n"

    # ⚠ 防锁定: 检查是否存在有 sudo 权限的非 root 用户
    local has_sudo_user=false
    local u
    while IFS= read -r u; do
        if groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
            has_sudo_user=true; break
        fi
    done < <(awk -F: '$3>=1000 && $7!~/nologin|false/{print $1}' /etc/passwd)
    if [[ "$has_sudo_user" == false && "$has_keys" == false ]]; then
        ssh_config+="PermitRootLogin yes\n"
        log "WARN" "⚠ 无 sudo 用户且无 SSH 密钥，保留 root 完整登录（请尽快创建普通用户并配置密钥）"
    else
        ssh_config+="PermitRootLogin prohibit-password\n"
    fi

    ssh_config+="PermitEmptyPasswords no\n"
    ssh_config+="MaxAuthTries 3\n"
    ssh_config+="MaxSessions 5\n"
    ssh_config+="LoginGraceTime 30\n"
    ssh_config+="PubkeyAuthentication yes\n"

    if [[ "$has_keys" == true ]]; then
        ssh_config+="PasswordAuthentication no\n"
        ssh_config+="KbdInteractiveAuthentication no\n"
        log "INFO" "检测到密钥，禁用密码登录"
    else
        ssh_config+="PasswordAuthentication yes\n"
        log "WARN" "未检测到 SSH 密钥，保留密码登录（建议尽快配置密钥）"
    fi

    ssh_config+="\n# 加密算法 (Ed25519 优先)\n"
    ssh_config+="HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256\n"
    ssh_config+="KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512\n"
    ssh_config+="Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr\n"
    ssh_config+="MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com\n"

    ssh_config+="\n# 转发与隧道\n"
    if [[ "$SSH_MODE" == "dev" ]]; then
        ssh_config+="AllowTcpForwarding yes\n"
        ssh_config+="AllowStreamLocalForwarding yes\n"
        ssh_config+="GatewayPorts no\n"
        ssh_config+="PermitTunnel no\n"
        ssh_config+="X11Forwarding yes\n"
        log "INFO" "开发模式: 允许 TCP/StreamLocal 转发 (兼容 VSCode Remote-SSH / Copilot)"
    else
        ssh_config+="AllowTcpForwarding no\n"
        ssh_config+="AllowStreamLocalForwarding no\n"
        ssh_config+="GatewayPorts no\n"
        ssh_config+="PermitTunnel no\n"
        ssh_config+="X11Forwarding no\n"
        log "INFO" "生产模式: 禁用所有转发"
    fi

    ssh_config+="\n# 其他安全选项\n"
    ssh_config+="UsePAM yes\n"
    ssh_config+="PrintMotd no\n"
    ssh_config+="UseDNS no\n"
    ssh_config+="StrictModes yes\n"
    ssh_config+="IgnoreRhosts yes\n"
    ssh_config+="HostbasedAuthentication no\n"
    ssh_config+="ClientAliveInterval 300\n"
    ssh_config+="ClientAliveCountMax 2\n"
    ssh_config+="Banner /etc/issue.net\n"
    ssh_config+="LogLevel VERBOSE\n"
    ssh_config+="Subsystem sftp /usr/lib/openssh/sftp-server\n"

    # 写入配置
    echo -e "$ssh_config" > "$sshd_conf"

    # 处理 sshd_config.d 下的 cloud-init 等覆盖配置
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] || continue
            backup_file "$f"
            # 删除可能覆盖我们配置的选项
            sed -i '/^PasswordAuthentication/d' "$f"
            sed -i '/^PermitRootLogin/d' "$f"
            sed -i '/^ChallengeResponseAuthentication/d' "$f"
            sed -i '/^KbdInteractiveAuthentication/d' "$f"
            sed -i '/^PubkeyAuthentication/d' "$f"
            sed -i '/^MaxAuthTries/d' "$f"
            # 如果文件变为空（仅注释/空行），则删除
            if ! grep -qE '^\s*[^#[:space:]]' "$f" 2>/dev/null; then
                rm -f "$f"
                log "INFO" "已移除空的 sshd drop-in 配置: $f"
            else
                log "INFO" "已清理 sshd drop-in 配置冲突项: $f"
            fi
        done
    fi

    # 生成 Ed25519 主机密钥（如果不存在）
    if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" >/dev/null 2>&1
        log "INFO" "已生成 Ed25519 主机密钥"
    fi

    # Ubuntu 22.04+ 使用 systemd ssh.socket 做 socket activation
    # ssh.socket 硬编码 ListenStream=22 会覆盖 sshd_config 中的 Port 设置
    # 必须同步修改 ssh.socket，否则端口变更不生效！
    if systemctl is-enabled ssh.socket &>/dev/null 2>&1; then
        local socket_override="/etc/systemd/system/ssh.socket.d"
        mkdir -p "$socket_override"
        # 备份现有 override
        [[ -f "$socket_override/override.conf" ]] && backup_file "$socket_override/override.conf"
        cat > "$socket_override/override.conf" << EOF
# sec-harden.sh: 同步 SSH 端口到 ssh.socket
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
        systemctl daemon-reload
        log "INFO" "已更新 ssh.socket 端口为 $SSH_PORT (systemd socket activation)"
        # 回滚
        echo "rm -f '$socket_override/override.conf' && systemctl daemon-reload && systemctl restart ssh.socket 2>/dev/null || true" >> "$ROLLBACK_SCRIPT"
    fi

    # 验证配置并重启（非 reload，确保新端口生效）
    # 确保 sshd 权限分离目录存在 (某些环境 /run/sshd 可能未创建)
    [[ ! -d /run/sshd ]] && mkdir -p /run/sshd
    if sshd -t 2>/dev/null; then
        # ⚠ 防锁定: 如果 UFW 已启用，先放行新端口再重启 SSH
        if ufw status 2>/dev/null | grep -qi 'active'; then
            ufw allow "$SSH_PORT"/tcp comment "SSH-pre-restart" >/dev/null 2>&1
            log "INFO" "UFW 已启用，预先放行 SSH 端口 $SSH_PORT"
        fi
        # 重启而非 reload，因为 reload 不会重新绑定端口
        if systemctl is-active ssh.socket &>/dev/null 2>&1; then
            systemctl restart ssh.socket 2>/dev/null || true
            systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
        log "INFO" "SSH 配置已应用并重启 (端口 $SSH_PORT)"
    else
        log "ERROR" "SSH 配置验证失败，正在回滚..."
        cp "${BACKUP_DIR}/etc/ssh/sshd_config" "$sshd_conf" 2>/dev/null || true
        log "ERROR" "已回滚 sshd_config，SSH 将使用原配置"
        return
    fi

    # 关键安全检查: 确认 SSH 确实在新端口监听，失败则自动回滚
    sleep 1
    if ss -tlnp | grep -q ":${SSH_PORT} "; then
        log "INFO" "✓ SSH 端口 $SSH_PORT 监听已确认"
    else
        log "ERROR" "✗ SSH 端口 $SSH_PORT 未监听！正在自动回滚配置..."
        cp "${BACKUP_DIR}/etc/ssh/sshd_config" "$sshd_conf" 2>/dev/null || true
        # 回滚 ssh.socket override
        if [[ -f "${BACKUP_DIR}/etc/systemd/system/ssh.socket.d/override.conf" ]]; then
            cp "${BACKUP_DIR}/etc/systemd/system/ssh.socket.d/override.conf" /etc/systemd/system/ssh.socket.d/override.conf 2>/dev/null || true
        else
            rm -f /etc/systemd/system/ssh.socket.d/override.conf 2>/dev/null || true
        fi
        systemctl daemon-reload 2>/dev/null || true
        if systemctl is-active ssh.socket &>/dev/null 2>&1; then
            systemctl restart ssh.socket 2>/dev/null || true
        fi
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        log "ERROR" "已回滚 SSH 配置并重启 (当前监听: $(ss -tlnp | grep ssh | awk '{print $4}'))"
    fi

    # 回滚脚本追加 SSH 重启
    echo "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 2: UFW 防火墙
###############################################################################
setup_ufw() {
    step_banner 2 "UFW 防火墙"
    
    apt-get install -y --no-install-recommends ufw >/dev/null 2>&1 || true

    # 备份现有规则
    if [[ -f /etc/ufw/user.rules ]]; then
        backup_file "/etc/ufw/user.rules"
        backup_file "/etc/ufw/user6.rules"
    fi

    # 重置 UFW（非交互）
    echo "y" | ufw reset >/dev/null 2>&1

    # ⚠ 关键安全: 重置后立即放行 SSH，防止脚本中途失败导致锁死
    # 同时放行当前实际监听端口（可能和目标端口不同）
    # 注意: RESTRICT_IP 限制从一开始就生效，避免宽泛规则覆盖精确规则
    local cur_ssh_listen
    cur_ssh_listen=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    [[ -z "$cur_ssh_listen" ]] && cur_ssh_listen="22"
    if [[ -n "$RESTRICT_IP" ]]; then
        IFS=',' read -ra IPS <<< "$RESTRICT_IP"
        for ip in "${IPS[@]}"; do
            ip=$(echo "$ip" | xargs)
            ufw allow from "$ip" to any port "$SSH_PORT" proto tcp comment "SSH from $ip" >/dev/null 2>&1
            if [[ "$cur_ssh_listen" != "$SSH_PORT" ]]; then
                ufw allow from "$ip" to any port "$cur_ssh_listen" proto tcp comment "SSH-current from $ip" >/dev/null 2>&1
            fi
            log "INFO" "UFW: 放行 SSH($SSH_PORT) 来自 $ip"
        done
    else
        ufw allow "$SSH_PORT"/tcp comment "SSH" >/dev/null 2>&1
        if [[ "$cur_ssh_listen" != "$SSH_PORT" ]]; then
            ufw allow "$cur_ssh_listen"/tcp comment "SSH-current" >/dev/null 2>&1
            log "INFO" "UFW: 安全放行当前SSH端口 $cur_ssh_listen + 目标端口 $SSH_PORT"
        fi
        log "INFO" "UFW: 放行 SSH($SSH_PORT)"
    fi

    # 默认策略
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # 放行 HTTP/HTTPS
    if [[ "$ALLOW_HTTP" == "yes" ]]; then
        ufw allow 80/tcp comment "HTTP" >/dev/null 2>&1
        ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1
        log "INFO" "UFW: 放行 80/443"
    fi

    # 自动检测 1Panel 端口
    local panel_ports
    panel_ports=$(detect_1panel_ports)
    if [[ -n "$panel_ports" ]]; then
        for port in $panel_ports; do
            if [[ -n "$RESTRICT_IP" ]]; then
                IFS=',' read -ra IPS <<< "$RESTRICT_IP"
                for ip in "${IPS[@]}"; do
                    ip=$(echo "$ip" | xargs)
                    ufw allow from "$ip" to any port "$port" proto tcp comment "1Panel from $ip" >/dev/null 2>&1
                done
            else
                ufw allow "$port"/tcp comment "1Panel" >/dev/null 2>&1
            fi
            log "INFO" "UFW: 放行 1Panel 端口 $port"
        done
    fi

    # Docker 兼容: 确保 UFW 不阻断 Docker 容器网络
    if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null; then
        local docker_after="/etc/ufw/after.rules"
        backup_file "$docker_after"
        if ! grep -q 'DOCKER-USER' "$docker_after" 2>/dev/null; then
            cat >> "$docker_after" << 'DOCKERUFW'

# sec-harden.sh: Docker UFW 兼容 — 允许容器间通信和 localhost 访问
*filter
:ufw-user-forward - [0:0]
-A ufw-user-forward -i docker0 -j ACCEPT
-A ufw-user-forward -o docker0 -j ACCEPT
-A ufw-user-forward -i br-+ -j ACCEPT
-A ufw-user-forward -o br-+ -j ACCEPT
COMMIT
DOCKERUFW
            log "INFO" "UFW: 已添加 Docker 兼容规则"
        fi
        # 确保 Docker iptables 不受 UFW FORWARD 策略影响
        local ufw_default="/etc/default/ufw"
        backup_file "$ufw_default"
        sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$ufw_default" 2>/dev/null || true
        log "INFO" "UFW: FORWARD 策略设为 ACCEPT (Docker 兼容)"
    fi

    # 启用 UFW
    if ! confirm_dangerous "即将启用 UFW 防火墙 (已放行端口: SSH=$SSH_PORT${ALLOW_HTTP:+, 80, 443}${panel_ports:+, 1Panel=$panel_ports})"; then
        log "WARN" "用户取消 UFW 启用"
        return
    fi
    echo "y" | ufw enable >/dev/null 2>&1
    log "INFO" "UFW 防火墙已启用"

    # 验证: 确认 SSH 端口被放行
    if ufw status | grep -q "$SSH_PORT/tcp.*ALLOW"; then
        log "INFO" "✓ UFW 已确认放行 SSH 端口 $SSH_PORT"
    else
        log "ERROR" "✗ UFW 未放行 SSH 端口 $SSH_PORT！紧急添加..."
        ufw allow "$SSH_PORT"/tcp comment "SSH-emergency" >/dev/null 2>&1
    fi

    # 回滚
    echo "echo y | ufw disable && echo '已禁用 UFW'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 3: Fail2ban
###############################################################################
setup_fail2ban() {
    step_banner 3 "Fail2ban 防暴力破解"

    # ⚠ 检测已有 Fail2ban（可能由 1Panel 等面板安装并管理）
    if systemctl is-active fail2ban &>/dev/null; then
        log "WARN" "检测到 Fail2ban 已在运行（可能由 1Panel 或其他面板安装）"
        if ! confirm_dangerous "将覆盖现有 Fail2ban 配置（已备份），如果面板已管理 Fail2ban 建议跳过"; then
            log "WARN" "跳过 Fail2ban 配置（保留现有面板管理）"
            return
        fi
        # 备份 jail.d 目录下的面板配置
        for f in /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local; do
            [[ -f "$f" ]] && backup_file "$f"
        done
    fi

    apt-get install -y --no-install-recommends fail2ban >/dev/null 2>&1 || true

    backup_file "/etc/fail2ban/jail.local"

    # 自动检测 Nginx/OpenResty 日志路径 (兼容 1Panel / 宝塔 / 原生安装)
    local nginx_error_log="" nginx_access_log=""
    local search_paths=(
        "/opt/1panel/apps/openresty/openresty/log"
        "/opt/1panel/apps/nginx/nginx/log"
        "/www/server/nginx/logs"
        "/var/log/nginx"
    )
    for p in "${search_paths[@]}"; do
        if [[ -f "$p/error.log" ]]; then
            nginx_error_log="$p/error.log"
            nginx_access_log="$p/access.log"
            log "INFO" "检测到 Nginx 日志路径: $p"
            break
        fi
    done
    # Docker 容器挂载检测
    if [[ -z "$nginx_error_log" ]] && command -v docker &>/dev/null; then
        local nginx_ctr
        nginx_ctr=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' 'tolower($2)~/openresty|nginx/{print $1; exit}')
        if [[ -n "$nginx_ctr" ]]; then
            local mnt
            mnt=$(docker inspect "$nginx_ctr" --format '{{range .Mounts}}{{if eq .Destination "/usr/local/openresty/nginx/logs"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
            [[ -z "$mnt" ]] && mnt=$(docker inspect "$nginx_ctr" --format '{{range .Mounts}}{{if eq .Destination "/var/log/nginx"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
            if [[ -n "$mnt" && -f "$mnt/error.log" ]]; then
                nginx_error_log="$mnt/error.log"
                nginx_access_log="$mnt/access.log"
                log "INFO" "通过 Docker 挂载检测到 Nginx 日志: $mnt"
            fi
        fi
    fi

    cat > /etc/fail2ban/jail.local << EOF
# === sec-harden.sh Fail2ban 配置 ===
[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = 600
maxretry = ${FAIL2BAN_MAXRETRY}
banaction = ufw
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = ${FAIL2BAN_MAXRETRY}
bantime  = ${FAIL2BAN_BANTIME}

[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
bantime  = 86400
findtime = 86400
maxretry = 3
EOF

    # 仅在检测到 Nginx 日志时添加 Nginx jail
    if [[ -n "$nginx_error_log" ]]; then
        cat >> /etc/fail2ban/jail.local << EOF

[nginx-limit-req]
enabled  = false
port     = http,https
filter   = nginx-limit-req
logpath  = ${nginx_error_log}
maxretry = 5
bantime  = 3600
findtime = 120

[nginx-botsearch]
enabled  = false
port     = http,https
filter   = nginx-botsearch
logpath  = ${nginx_access_log}
maxretry = 3
bantime  = 86400
findtime = 60
EOF
        log "INFO" "Fail2ban: 已添加 Nginx jail (日志: $nginx_error_log)"
    else
        log "INFO" "Fail2ban: 未检测到 Nginx 日志路径，跳过 Nginx jail"
    fi

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log "INFO" "Fail2ban 已配置并启动 (maxretry=$FAIL2BAN_MAXRETRY, bantime=$FAIL2BAN_BANTIME)"

    echo "systemctl stop fail2ban && rm -f /etc/fail2ban/jail.local && echo '已移除 Fail2ban 配置'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 4: 内核安全参数 sysctl
###############################################################################
harden_sysctl() {
    step_banner 4 "内核安全参数 sysctl"

    local sysctl_file="/etc/sysctl.d/99-sec-harden.conf"
    backup_file "$sysctl_file"

    cat > "$sysctl_file" << EOF
# === sec-harden.sh 内核安全参数 ===

# 防 SYN Flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# 禁止 ICMP 重定向
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# 禁止 IP 源路由
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# 反向路径过滤
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 忽略 ICMP 广播
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ASLR 地址空间随机化
kernel.randomize_va_space = 2

# 限制 ptrace 调试
kernel.yama.ptrace_scope = 2

# 禁止非特权用户查看 dmesg
kernel.dmesg_restrict = 1

# SysRq: 仅允许 sync + remount-ro + reboot (紧急恢复最小集)
kernel.sysrq = 176

# 禁止非特权用户使用 bpf / userfaultfd
kernel.unprivileged_bpf_disabled = 1
# kernel.unprivileged_userns_clone — 仅 Debian/Ubuntu 特定内核补丁, 标准 Ubuntu 24.04 内核不存在此选项
# 如内核支持则取消注释: kernel.unprivileged_userns_clone = 0
EOF

    # 可选: 禁止 ICMP ping
    if [[ "$DISABLE_PING" == "yes" ]]; then
        echo "net.ipv4.icmp_echo_ignore_all = 1" >> "$sysctl_file"
        log "INFO" "已禁止 ICMP ping"
    fi

    # 可选: 禁用 IPv6
    if [[ "$DISABLE_IPV6" == "yes" ]]; then
        cat >> "$sysctl_file" << 'EOF'

# 禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        log "INFO" "已禁用 IPv6"
    fi

    sysctl --system >/dev/null 2>&1
    log "INFO" "内核安全参数已应用"

    echo "rm -f '$sysctl_file' && sysctl --system >/dev/null 2>&1 && echo '已移除内核安全参数'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 5: 禁用危险内核模块
###############################################################################
disable_kernel_modules() {
    step_banner 5 "禁用危险内核模块"

    local modfile="/etc/modprobe.d/sec-harden-blacklist.conf"
    backup_file "$modfile"

    local modules=(
        dccp sctp tipc rds
        cramfs freevxfs hfs hfsplus jffs2 udf
        usb-storage
    )

    {
        echo "# === sec-harden.sh 内核模块黑名单 ==="
        for mod in "${modules[@]}"; do
            echo "install $mod /bin/true"
            echo "blacklist $mod"
        done
    } > "$modfile"

    # 卸载已加载的模块
    for mod in "${modules[@]}"; do
        modprobe -r "$mod" 2>/dev/null || true
    done

    # 更新 initramfs
    if command -v update-initramfs &>/dev/null; then
        update-initramfs -u -k all >/dev/null 2>&1 || true
        log "INFO" "initramfs 已更新"
    fi

    log "INFO" "已禁用 ${#modules[@]} 个危险内核模块"

    echo "rm -f '$modfile' && update-initramfs -u -k all >/dev/null 2>&1 && echo '已移除内核模块黑名单'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 6: SUID/SGID 清理
###############################################################################
clean_suid() {
    step_banner 6 "SUID/SGID 清理"

    local suid_targets=(
        /usr/bin/chfn
        /usr/bin/chsh
        /usr/bin/wall
        /usr/bin/newgrp
        /usr/bin/gpasswd
        /usr/bin/mount
        /usr/bin/umount
        /usr/bin/ssh-agent
    )

    local cleaned=0
    for bin in "${suid_targets[@]}"; do
        if [[ -f "$bin" ]]; then
            local perms
            perms=$(stat -c '%a' "$bin")
            if [[ $((0$perms & 04000)) -ne 0 || $((0$perms & 02000)) -ne 0 ]]; then
                # 记录原始权限用于回滚
                echo "chmod $perms '$bin' && echo '已恢复 SUID: $bin'" >> "$ROLLBACK_SCRIPT"
                chmod u-s,g-s "$bin"
                cleaned=$((cleaned + 1))
                log "INFO" "已去除 SUID/SGID: $bin"
            fi
        fi
    done

    # dpkg hook 防止 apt 恢复 SUID
    local dpkg_hook="/etc/apt/apt.conf.d/99-sec-harden-suid"
    cat > "$dpkg_hook" << 'EOF'
// sec-harden.sh: 阻止 apt 恢复 SUID 位
DPkg::Post-Invoke {
    "chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/wall /usr/bin/newgrp 2>/dev/null || true";
    "chmod u-s /usr/bin/gpasswd /usr/bin/mount /usr/bin/umount /usr/bin/ssh-agent 2>/dev/null || true";
};
EOF

    log "INFO" "已清理 $cleaned 个 SUID/SGID 文件，已创建 dpkg hook"

    echo "rm -f '$dpkg_hook' && echo '已移除 dpkg SUID hook'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 7: 密码策略
###############################################################################
setup_password_policy() {
    step_banner 7 "密码策略"

    apt-get install -y --no-install-recommends libpam-pwquality >/dev/null 2>&1 || true

    # pwquality 配置
    local pwq="/etc/security/pwquality.conf"
    backup_file "$pwq"
    cat > "$pwq" << EOF
# === sec-harden.sh 密码强度策略 ===
minlen = ${PASSWORD_MIN_LEN}
minclass = ${PASSWORD_MIN_CLASS}
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
maxrepeat = 3
maxsequence = 3
dictcheck = 1
usercheck = 1
enforcing = 1
retry = 3
EOF

    # faillock 配置（Ubuntu 24.04 使用 pam_faillock）
    local faillock_conf="/etc/security/faillock.conf"
    backup_file "$faillock_conf"
    cat > "$faillock_conf" << EOF
# === sec-harden.sh faillock 配置 ===
deny = ${FAILLOCK_ATTEMPTS}
unlock_time = ${FAILLOCK_LOCKTIME}
fail_interval = 900
# even_deny_root  # 不锁定 root，防止攻击者通过故意失败登录将管理员锁在门外
root_unlock_time = ${FAILLOCK_LOCKTIME}
dir = /var/run/faillock
audit
EOF

    # login.defs
    local logindefs="/etc/login.defs"
    backup_file "$logindefs"
    sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   ${PASSWORD_MAX_DAYS}/" "$logindefs"
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' "$logindefs"
    sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' "$logindefs"

    # PAM 记住旧密码 (pam_pwhistory)
    local common_password="/etc/pam.d/common-password"
    backup_file "$common_password"
    if ! grep -q 'pam_pwhistory' "$common_password" 2>/dev/null; then
        sed -i '/pam_pwquality/a password\trequired\t\t\tpam_pwhistory.so remember=5 enforce_for_root use_authtok' "$common_password" 2>/dev/null || true
    fi

    log "INFO" "密码策略: minlen=$PASSWORD_MIN_LEN, faillock=${FAILLOCK_ATTEMPTS}次/${FAILLOCK_LOCKTIME}秒, 过期${PASSWORD_MAX_DAYS}天"

    echo "# 密码策略回滚需手动恢复备份文件" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 8: 文件权限加固
###############################################################################
harden_file_permissions() {
    step_banner 8 "文件权限加固"

    local files_600=(
        /etc/shadow
        /etc/gshadow
        /etc/ssh/sshd_config
        /etc/crontab
    )

    local files_grub=(
        /boot/grub/grub.cfg
        /boot/grub2/grub.cfg
    )

    local dirs_700=(
        /etc/cron.d
        /etc/cron.daily
        /etc/cron.hourly
        /etc/cron.monthly
        /etc/cron.weekly
    )

    for f in "${files_600[@]}"; do
        if [[ -f "$f" ]]; then
            local old_perms
            old_perms=$(stat -c '%a' "$f")
            echo "chmod $old_perms '$f'" >> "$ROLLBACK_SCRIPT"
            chmod 600 "$f"
            log "INFO" "权限 600: $f"
        fi
    done

    for f in "${files_grub[@]}"; do
        if [[ -f "$f" ]]; then
            local old_perms
            old_perms=$(stat -c '%a' "$f")
            echo "chmod $old_perms '$f'" >> "$ROLLBACK_SCRIPT"
            chmod 600 "$f"
            log "INFO" "权限 600: $f"
        fi
    done

    for d in "${dirs_700[@]}"; do
        if [[ -d "$d" ]]; then
            local old_perms
            old_perms=$(stat -c '%a' "$d")
            echo "chmod $old_perms '$d'" >> "$ROLLBACK_SCRIPT"
            chmod 700 "$d"
            log "INFO" "权限 700: $d"
        fi
    done
}

###############################################################################
#  模块 9: 服务精简
###############################################################################
minimize_services() {
    step_banner 9 "服务精简"

    local services_to_disable=(
        avahi-daemon
        cups
        cups-browsed
        ModemManager
        upower
        udisks2
        rpcbind
        nfs-common
        nfs-kernel-server
    )

    for svc in "${services_to_disable[@]}"; do
        if systemctl is-active "$svc" &>/dev/null || systemctl is-enabled "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
            log "INFO" "已禁用服务: $svc"
            echo "systemctl unmask '$svc' && systemctl enable '$svc' 2>/dev/null && echo '已恢复服务: $svc'" >> "$ROLLBACK_SCRIPT"
        fi
    done

    # 卸载不安全的软件包
    local pkgs_to_remove=(telnetd rsh-server nis tftp tftpd)
    for pkg in "${pkgs_to_remove[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            apt-get purge -y "$pkg" >/dev/null 2>&1 || true
            log "INFO" "已卸载: $pkg"
        fi
    done
}

###############################################################################
#  模块 10: 审计日志 auditd
###############################################################################
setup_auditd() {
    step_banner 10 "审计日志 auditd"

    apt-get install -y --no-install-recommends auditd audispd-plugins >/dev/null 2>&1 || true

    local audit_rules="/etc/audit/rules.d/sec-harden.rules"
    backup_file "$audit_rules"

    cat > "$audit_rules" << 'EOF'
# === sec-harden.sh 审计规则 ===

# 监控用户/组文件变更
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity

# 监控 sudoers
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# 监控 SSH 配置
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# 内核模块加载
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/rmmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k kernel_modules

# 权限修改
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod

# 时间修改
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time_change
-w /etc/localtime -p wa -k time_change

# 文件删除
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=4294967295 -k file_deletion

# 挂载操作
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts

# 登录/登出
-w /var/log/lastlog -p wa -k logins
-w /var/log/faillog -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

# 使配置不可变（建议生产环境启用）
# -e 2
EOF

    # 重启 auditd
    systemctl enable auditd >/dev/null 2>&1
    systemctl restart auditd >/dev/null 2>&1 || augenrules --load >/dev/null 2>&1 || true
    log "INFO" "审计日志已配置并启动"

    echo "rm -f '$audit_rules' && systemctl restart auditd 2>/dev/null && echo '已移除审计规则'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 11: 自动安全更新
###############################################################################
setup_auto_updates() {
    step_banner 11 "自动安全更新"

    apt-get install -y --no-install-recommends unattended-upgrades apt-listchanges >/dev/null 2>&1 || true

    local auto_conf="/etc/apt/apt.conf.d/20auto-upgrades"
    backup_file "$auto_conf"

    cat > "$auto_conf" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

    local uu_conf="/etc/apt/apt.conf.d/50unattended-upgrades"
    backup_file "$uu_conf"

    # 确保安全更新源已启用
    if [[ -f "$uu_conf" ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        local distro_id="${ID:-ubuntu}"
        local distro_codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo jammy)}"
        sed -i "s|//\\s*\"${distro_id}:${distro_codename}-security\"|\"${distro_id}:${distro_codename}-security\"|" "$uu_conf"
    fi

    systemctl enable unattended-upgrades >/dev/null 2>&1
    log "INFO" "自动安全更新已启用（每日检查）"
}

###############################################################################
#  模块 12: 核心转储禁用
###############################################################################
disable_core_dumps() {
    step_banner 12 "核心转储禁用"

    # limits.conf
    local limits="/etc/security/limits.d/99-sec-harden-coredump.conf"
    backup_file "$limits"
    cat > "$limits" << 'EOF'
# sec-harden.sh: 禁用核心转储
*     hard   core    0
*     soft   core    0
root  hard   core    0
root  soft   core    0
EOF

    # systemd coredump
    local coredump="/etc/systemd/coredump.conf.d"
    mkdir -p "$coredump"
    cat > "$coredump/sec-harden.conf" << 'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

    # sysctl
    local sysctl_core="/etc/sysctl.d/99-sec-harden-coredump.conf"
    cat > "$sysctl_core" << 'EOF'
# sec-harden.sh: 禁用核心转储
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false
EOF
    sysctl --system >/dev/null 2>&1

    log "INFO" "核心转储已禁用 (limits + systemd + sysctl)"

    echo "rm -f '$limits' '$coredump/sec-harden.conf' '$sysctl_core' && sysctl --system >/dev/null 2>&1 && echo '已恢复核心转储设置'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 13: 临时目录加固
###############################################################################
harden_tmp() {
    step_banner 13 "临时目录加固"

    backup_file "/etc/fstab"

    local fstab="/etc/fstab"
    local changed=false

    # /tmp — nosuid,nodev
    if ! grep -qE '^\S+\s+/tmp\s' "$fstab"; then
        # 如果 /tmp 不在 fstab 中，添加 tmpfs 挂载
        if ! findmnt /tmp >/dev/null 2>&1 || findmnt -n -o FSTYPE /tmp 2>/dev/null | grep -qv tmpfs; then
            echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,noatime,size=512m 0 0" >> "$fstab"
            changed=true
            log "INFO" "/tmp: 添加 tmpfs 挂载 (nosuid,nodev)"
        fi
    else
        if ! grep -E '^\S+\s+/tmp\s' "$fstab" | grep -q 'nosuid'; then
            sed -i '/\s\/tmp\s/{s/defaults/defaults,nosuid,nodev/}' "$fstab"
            changed=true
            log "INFO" "/tmp: 添加 nosuid,nodev 选项"
        fi
    fi

    # /dev/shm — noexec
    if ! grep -qE '^\S+\s+/dev/shm\s' "$fstab"; then
        echo "tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >> "$fstab"
        changed=true
        log "INFO" "/dev/shm: 添加 noexec 选项"
    else
        if ! grep -E '^\S+\s+/dev/shm\s' "$fstab" | grep -q 'noexec'; then
            sed -i '/\s\/dev\/shm\s/{s/defaults/defaults,nosuid,nodev,noexec/}' "$fstab"
            changed=true
            log "INFO" "/dev/shm: 添加 noexec 选项"
        fi
    fi

    # /var/tmp — noexec (bind mount)
    if ! grep -qE '^\S+\s+/var/tmp\s' "$fstab"; then
        echo "tmpfs /var/tmp tmpfs defaults,nosuid,nodev,noexec,size=256m 0 0" >> "$fstab"
        changed=true
        log "INFO" "/var/tmp: 添加 noexec 选项"
    fi

    if [[ "$changed" == true ]]; then
        mount -o remount /tmp 2>/dev/null || true
        mount -o remount /dev/shm 2>/dev/null || true
        log "INFO" "临时目录加固完成（部分可能需重启生效）"
    else
        log "INFO" "临时目录已满足安全要求"
    fi
}

###############################################################################
#  模块 14: su 限制
###############################################################################
restrict_su() {
    step_banner 14 "su 限制"

    local pam_su="/etc/pam.d/su"
    backup_file "$pam_su"

    # 启用 pam_wheel — 仅 sudo 组可以 su
    if grep -q '^#.*pam_wheel.so' "$pam_su" 2>/dev/null; then
        sed -i 's/^#\s*\(auth\s\+required\s\+pam_wheel.so\)/\1/' "$pam_su"
        log "INFO" "已启用 pam_wheel: 仅 sudo 组可使用 su"
    elif ! grep -q 'pam_wheel.so' "$pam_su" 2>/dev/null; then
        sed -i '/pam_rootok/a auth       required   pam_wheel.so group=sudo' "$pam_su"
        log "INFO" "已添加 pam_wheel: 仅 sudo 组可使用 su"
    else
        log "INFO" "pam_wheel 已配置"
    fi
}

###############################################################################
#  模块 15: Shell 安全
###############################################################################
harden_shell() {
    step_banner 15 "Shell 安全"

    # TMOUT 超时
    local profile_sec="/etc/profile.d/sec-harden.sh"
    backup_file "$profile_sec"

    if [[ "$SSH_MODE" == "dev" ]]; then
        cat > "$profile_sec" << 'EOF'
# === sec-harden.sh Shell 安全 (开发模式) ===
# 开发模式: 不设置 TMOUT (兼容 VSCode Remote-SSH / Copilot)

# 安全别名
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
EOF
        log "INFO" "开发模式: 跳过 TMOUT 设置 (兼容 VSCode)"
    else
        cat > "$profile_sec" << EOF
# === sec-harden.sh Shell 安全 ===
# 会话超时 (秒)
readonly TMOUT=${SHELL_TMOUT}
export TMOUT

# 安全别名
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
EOF
    fi
    chmod 644 "$profile_sec"

    # 登录警告横幅
    local issue_net="/etc/issue.net"
    backup_file "$issue_net"
    cat > "$issue_net" << 'EOF'
***************************************************************************
                  AUTHORIZED ACCESS ONLY
  This system is restricted to authorized users. All activities
  are monitored and logged. Unauthorized access is prohibited
  and will be prosecuted to the fullest extent of the law.
***************************************************************************
EOF

    local issue="/etc/issue"
    backup_file "$issue"
    cp "$issue_net" "$issue"

    # hosts.allow — 必须在 hosts.deny 之前配置，否则会锁死 SSH!
    local hosts_allow="/etc/hosts.allow"
    backup_file "$hosts_allow"
    if ! grep -q 'sshd: ALL' "$hosts_allow" 2>/dev/null; then
        cat >> "$hosts_allow" << 'HOSTALLOW'
# sec-harden.sh: SSH 必须允许所有来源 (安全由 UFW+Fail2ban 保障)
sshd: ALL
# 允许本地和 Docker 内部通信
ALL: 127.0.0.1
ALL: 172.16.0.0/12
ALL: 192.168.0.0/16
ALL: 10.0.0.0/8
HOSTALLOW
        log "INFO" "hosts.allow: 已添加 sshd:ALL + 本地/Docker 白名单"
    fi

    # hosts.deny (hosts.allow 优先级更高，匹配后不再查 deny)
    local hosts_deny="/etc/hosts.deny"
    backup_file "$hosts_deny"
    if ! grep -q 'ALL: ALL' "$hosts_deny" 2>/dev/null; then
        echo "ALL: ALL" >> "$hosts_deny"
        log "INFO" "hosts.deny: ALL: ALL (sshd 已在 hosts.allow 中豁免)"
    fi

    log "INFO" "Shell 安全: TMOUT=$SHELL_TMOUT, Banner 已设置"

    echo "rm -f '$profile_sec' && echo '已移除 Shell 安全配置'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 16: AIDE 文件完整性
###############################################################################
setup_aide() {
    step_banner 16 "AIDE 文件完整性检测"

    apt-get install -y --no-install-recommends aide aide-common >/dev/null 2>&1 || true

    # 初始化数据库 (超时 300 秒以防止卡死; yes 自动应答覆盖提示)
    log "INFO" "正在初始化 AIDE 数据库（可能需要几分钟…）"
    yes | timeout 300 aideinit >/dev/null 2>&1 || timeout 300 aide --init >/dev/null 2>&1 || {
        log "WARN" "AIDE 初始化超时或失败，可稍后手动运行: aideinit"
    }

    # 如果生成了新数据库，移动到正确位置
    if [[ -f /var/lib/aide/aide.db.new ]]; then
        cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
    fi

    # 每日自动检查 cron
    local aide_cron="/etc/cron.daily/aide-check"
    cat > "$aide_cron" << 'AIDECRON'
#!/bin/bash
# sec-harden.sh: AIDE 每日完整性检查
LOG="/var/log/aide/aide-check-$(date +%F).log"
mkdir -p /var/log/aide
aide --check > "$LOG" 2>&1 || true
# 保留最近30天的日志
find /var/log/aide -name "*.log" -mtime +30 -delete 2>/dev/null || true
AIDECRON
    chmod 755 "$aide_cron"

    log "INFO" "AIDE 已初始化，每日自动检查已配置"

    echo "rm -f '$aide_cron' && echo '已移除 AIDE 定时检查'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 17: rkhunter rootkit 检测
###############################################################################
setup_rkhunter() {
    step_banner 17 "rkhunter rootkit 检测"

    apt-get install -y --no-install-recommends rkhunter >/dev/null 2>&1 || true

    # 更新数据库
    rkhunter --update 2>/dev/null || true
    rkhunter --propupd 2>/dev/null || true

    # 配置
    local rkhunter_conf="/etc/rkhunter.conf"
    backup_file "$rkhunter_conf"
    if [[ -f "$rkhunter_conf" ]]; then
        sed -i 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="true"/' "$rkhunter_conf" 2>/dev/null || true
        sed -i 's/^UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/' "$rkhunter_conf" 2>/dev/null || true
        sed -i 's/^MIRRORS_MODE=.*/MIRRORS_MODE=0/' "$rkhunter_conf" 2>/dev/null || true
        sed -i 's/^WEB_CMD=.*/WEB_CMD=""/' "$rkhunter_conf" 2>/dev/null || true
    fi

    # 配置每周自动扫描
    local rk_cron="/etc/cron.weekly/rkhunter-scan"
    cat > "$rk_cron" << 'RKCRON'
#!/bin/bash
# sec-harden.sh: rkhunter 每周 rootkit 扫描
LOG="/var/log/rkhunter-weekly-$(date +%F).log"
rkhunter --check --skip-keypress --report-warnings-only > "$LOG" 2>&1 || true
find /var/log -name "rkhunter-weekly-*.log" -mtime +60 -delete 2>/dev/null || true
RKCRON
    chmod 755 "$rk_cron"

    log "INFO" "rkhunter 已配置，每周自动扫描"

    echo "rm -f '$rk_cron' && echo '已移除 rkhunter 定时扫描'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  模块 18: MTA 锁定
###############################################################################
lockdown_mta() {
    step_banner 18 "MTA 锁定"

    if command -v postconf &>/dev/null; then
        backup_file "/etc/postfix/main.cf"
        postconf -e 'inet_interfaces = 127.0.0.1'
        postconf -e 'inet_protocols = ipv4'
        systemctl restart postfix 2>/dev/null || true
        log "INFO" "Postfix 已锁定为仅监听 127.0.0.1"
    elif dpkg -l postfix 2>/dev/null | grep -q '^ii'; then
        backup_file "/etc/postfix/main.cf"
        postconf -e 'inet_interfaces = 127.0.0.1'
        systemctl restart postfix 2>/dev/null || true
        log "INFO" "Postfix 已锁定为仅监听 127.0.0.1"
    else
        log "INFO" "未安装 Postfix，跳过 MTA 锁定"
    fi
}

###############################################################################
#  验证函数
###############################################################################
run_verification() {
    echo "" | tee -a "$LOG_FILE"
    printf '%b╔═══════════════════════════════════════════════════════════════╗%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b║                      验  证  结  果                          ║%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b╚═══════════════════════════════════════════════════════════════╝%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"

    PASS_COUNT=0; FAIL_COUNT=0; TOTAL_COUNT=0

    # SSH
    local sshd_conf="/etc/ssh/sshd_config"
    check_result "SSH 端口已更改为 $SSH_PORT" \
        "$(grep -qE "^Port $SSH_PORT" "$sshd_conf" 2>/dev/null && echo pass || echo fail)"
    check_result "SSH 实际监听端口 $SSH_PORT" \
        "$(ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} " && echo pass || echo fail)"
    check_result "SSH 禁止空密码" \
        "$(grep -qE '^PermitEmptyPasswords no' "$sshd_conf" 2>/dev/null && echo pass || echo fail)"
    check_result "SSH PermitRootLogin=prohibit-password" \
        "$(grep -qE '^PermitRootLogin prohibit-password' "$sshd_conf" 2>/dev/null && echo pass || echo fail)"
    check_result "SSH Ed25519 算法优先" \
        "$(grep -q 'ssh-ed25519' "$sshd_conf" 2>/dev/null && echo pass || echo fail)"

    # UFW
    check_result "UFW 已启用" \
        "$(ufw status 2>/dev/null | grep -qi 'active' && echo pass || echo fail)"

    # Fail2ban
    check_result "Fail2ban 正在运行" \
        "$(systemctl is-active fail2ban &>/dev/null && echo pass || echo fail)"

    # Sysctl
    check_result "SYN cookies 已启用" \
        "$([[ $(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) == "1" ]] && echo pass || echo fail)"
    check_result "ASLR 已启用 (=2)" \
        "$([[ $(sysctl -n kernel.randomize_va_space 2>/dev/null) == "2" ]] && echo pass || echo fail)"
    check_result "dmesg 已限制" \
        "$([[ $(sysctl -n kernel.dmesg_restrict 2>/dev/null) == "1" ]] && echo pass || echo fail)"

    # 内核模块黑名单
    check_result "内核模块黑名单已配置" \
        "$([[ -f /etc/modprobe.d/sec-harden-blacklist.conf ]] && echo pass || echo fail)"

    # SUID 清理
    check_result "chfn SUID 已去除" \
        "$(if [[ -f /usr/bin/chfn ]]; then [[ ! -u /usr/bin/chfn ]] && echo pass || echo fail; else echo pass; fi)"

    # 文件权限
    check_result "/etc/shadow 权限 600" \
        "$([[ $(stat -c '%a' /etc/shadow 2>/dev/null) == "600" ]] && echo pass || echo fail)"

    # 核心转储
    check_result "核心转储已禁用 (suid_dumpable=0)" \
        "$([[ $(sysctl -n fs.suid_dumpable 2>/dev/null) == "0" ]] && echo pass || echo fail)"

    # 服务
    check_result "ModemManager 已禁用" \
        "$(! systemctl is-active ModemManager &>/dev/null && echo pass || echo fail)"

    # 审计
    check_result "auditd 正在运行" \
        "$(systemctl is-active auditd &>/dev/null && echo pass || echo fail)"

    # Banner
    check_result "SSH Banner 已设置" \
        "$(grep -q 'AUTHORIZED ACCESS ONLY' /etc/issue.net 2>/dev/null && echo pass || echo fail)"

    # hosts.deny
    check_result "hosts.deny ALL:ALL" \
        "$(grep -q 'ALL: ALL' /etc/hosts.deny 2>/dev/null && echo pass || echo fail)"

    # su 限制
    check_result "su 限制 (pam_wheel)" \
        "$(grep -qE '^auth\s+required\s+pam_wheel' /etc/pam.d/su 2>/dev/null && echo pass || echo fail)"

    echo "" | tee -a "$LOG_FILE"
    local rate=0
    if [[ $TOTAL_COUNT -gt 0 ]]; then
        rate=$((PASS_COUNT * 100 / TOTAL_COUNT))
    fi
    printf '%b验证结果: %b✓ %d 通过%b / %b✗ %d 失败%b / 共 %d 项 (通过率 %d%%)%b\n' \
        "$BOLD" "$GREEN" "$PASS_COUNT" "$NC" "$RED" "$FAIL_COUNT" "$NC" "$TOTAL_COUNT" "$rate" "$NC" | tee -a "$LOG_FILE"
}

###############################################################################
#  生成 YAML 诊断报告
###############################################################################
generate_report() {
    local rate=0
    [[ $TOTAL_COUNT -gt 0 ]] && rate=$((PASS_COUNT * 100 / TOTAL_COUNT))

    cat > "$DIAG_FILE" << YAMLEOF
---
# sec-harden.sh 诊断报告
version: "$SCRIPT_VERSION"
generated_at: "$(date -Iseconds)"
hostname: "$(hostname)"
os: "$(. /etc/os-release && echo "$PRETTY_NAME")"
kernel: "$(uname -r)"
cpu_cores: $(nproc)
memory_total: "$(free -h | awk '/Mem:/{print $2}')"
disk_root: "$(df -h / | awk 'NR==2{print $2}')"

parameters:
  ssh_port: ${SSH_PORT}
  ssh_mode: "${SSH_MODE}"
  fail2ban_maxretry: ${FAIL2BAN_MAXRETRY}
  fail2ban_bantime: ${FAIL2BAN_BANTIME}
  password_min_len: ${PASSWORD_MIN_LEN}
  password_max_days: ${PASSWORD_MAX_DAYS}
  shell_tmout: ${SHELL_TMOUT}
  allow_http: "${ALLOW_HTTP}"
  disable_ipv6: "${DISABLE_IPV6}"
  disable_ping: "${DISABLE_PING}"
  restrict_ip: "${RESTRICT_IP}"

verification:
  total: ${TOTAL_COUNT}
  passed: ${PASS_COUNT}
  failed: ${FAIL_COUNT}
  pass_rate: "${rate}%"

backup:
  directory: "${BACKUP_DIR}"
  rollback_script: "${ROLLBACK_SCRIPT}"
  log_file: "${LOG_FILE}"

modules_executed:
  - ssh_hardening
  - ufw_firewall
  - fail2ban
  - sysctl_security
  - kernel_module_blacklist
  - suid_cleanup
  - password_policy
  - file_permissions
  - service_minimization
  - auditd
  - auto_updates
  - core_dump_disable
  - tmp_hardening
  - su_restriction
  - shell_security
  - aide
  - rkhunter
  - mta_lockdown
YAMLEOF

    log "INFO" "诊断报告: $DIAG_FILE"
}

###############################################################################
#  系统当前状态检测（交互模式用）
###############################################################################
show_current_status() {
    echo ""
    printf '%b═══ 当前系统安全状态 ═══%b\n' "${BOLD}${CYAN}" "${NC}"
    echo ""

    # SSH
    local cur_ssh_port
    cur_ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    [[ -z "$cur_ssh_port" ]] && cur_ssh_port="22"
    local cur_pwd_auth
    cur_pwd_auth=$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "yes")
    printf '  SSH 端口: %b%s%b  |  密码登录: %b%s%b\n' "${YELLOW}" "$cur_ssh_port" "${NC}" "${YELLOW}" "$cur_pwd_auth" "${NC}"

    # UFW
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 || echo "未安装")
    printf '  防火墙: %b%s%b\n' "${YELLOW}" "$ufw_status" "${NC}"

    # Fail2ban
    local f2b_status="未安装"
    if systemctl is-active fail2ban &>/dev/null; then f2b_status="运行中";
    elif command -v fail2ban-client &>/dev/null; then f2b_status="已安装未运行"; fi
    printf '  Fail2ban: %b%s%b\n' "${YELLOW}" "$f2b_status" "${NC}"

    # Docker 容器
    local docker_count
    docker_count=$( { docker ps -q 2>/dev/null || true; } | wc -l )
    printf '  Docker 容器: %b%s 运行中%b\n' "${YELLOW}" "$docker_count" "${NC}"

    # 1Panel
    local panel_ports
    panel_ports=$(detect_1panel_ports)
    printf '  1Panel 端口: %b%s%b\n' "${YELLOW}" "${panel_ports:-未检测到}" "${NC}"

    echo ""
}

###############################################################################
#  交互菜单
###############################################################################
interactive_menu() {
    show_current_status

    printf '%b═══ 安全加固配置 ═══%b\n' "${BOLD}${CYAN}" "${NC}"
    echo ""

    # SSH 模式
    printf '  SSH 模式 [%b1%b=生产模式(禁止转发) / %b2%b=开发模式(允许转发，兼容VSCode)]: ' "${YELLOW}" "${NC}" "${YELLOW}" "${NC}"
    read -r ssh_choice
    case "$ssh_choice" in
        2) SSH_MODE="dev" ;;
        *) SSH_MODE="prod" ;;
    esac

    # SSH 端口
    printf '  SSH 端口 [默认 %b%s%b]: ' "$YELLOW" "$SSH_PORT" "$NC"
    read -r port_input
    [[ -n "$port_input" ]] && SSH_PORT="$port_input"

    # 放行 HTTP/HTTPS
    printf '  放行 80/443 端口? [%bY%b/n]: ' "${YELLOW}" "${NC}"
    read -r http_choice
    case "$http_choice" in
        [nN]*) ALLOW_HTTP="no" ;;
        *) ALLOW_HTTP="yes" ;;
    esac

    # 禁用 IPv6
    printf '  禁用 IPv6? [y/%bN%b]: ' "${YELLOW}" "${NC}"
    read -r ipv6_choice
    case "$ipv6_choice" in
        [yY]*) DISABLE_IPV6="yes" ;;
        *) DISABLE_IPV6="no" ;;
    esac

    # 禁用 Ping
    printf '  禁止 ICMP Ping? [y/%bN%b]: ' "${YELLOW}" "${NC}"
    read -r ping_choice
    case "$ping_choice" in
        [yY]*) DISABLE_PING="yes" ;;
        *) DISABLE_PING="no" ;;
    esac

    # 限制 IP
    printf "  防火墙限制来源 IP (逗号分隔，留空不限制): "
    read -r ip_input
    [[ -n "$ip_input" ]] && RESTRICT_IP="$ip_input"

    echo ""
    printf '%b配置确认:%b\n' "${BOLD}" "${NC}"
    printf "  SSH: 端口=%s, 模式=%s\n" "$SSH_PORT" "$SSH_MODE"
    printf "  HTTP: %s  IPv6: %s  Ping: %s\n" "$ALLOW_HTTP" "$DISABLE_IPV6" "$DISABLE_PING"
    printf "  限制IP: %s\n" "${RESTRICT_IP:-无}"
    echo ""
    printf '  按 %bEnter%b 开始执行，%bCtrl+C%b 取消...' "${YELLOW}" "${NC}" "${YELLOW}" "${NC}"
    read -r
}

###############################################################################
#  运行后成果总结
###############################################################################
show_final_summary() {
    local rate=0
    [[ $TOTAL_COUNT -gt 0 ]] && rate=$((PASS_COUNT * 100 / TOTAL_COUNT))

    echo "" | tee -a "$LOG_FILE"
    printf '%b╔═══════════════════════════════════════════════════════════════╗%b\n' "${BOLD}${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b║                   安全加固完成                               ║%b\n' "${BOLD}${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b╚═══════════════════════════════════════════════════════════════╝%b\n' "${BOLD}${GREEN}" "${NC}" | tee -a "$LOG_FILE"

    # ── 前后对比表 ──
    echo "" | tee -a "$LOG_FILE"
    printf '%b┌─────────────────────┬──────────────────┬──────────────────┐%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b│ %-19s │ %-16s │ %-16s │%b\n' "${BOLD}${CYAN}" "项目" "加固前" "加固后" "${NC}" | tee -a "$LOG_FILE"
    printf '%b├─────────────────────┼──────────────────┼──────────────────┤%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"

    local after_port after_pwd after_root after_ufw after_f2b after_sync after_aslr after_core after_audit
    after_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "?")
    after_pwd=$(grep -E '^PasswordAuthentication ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "?")
    after_root=$(grep -E '^PermitRootLogin ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "?")
    after_ufw=$(ufw status 2>/dev/null | head -1 || echo "?")
    after_f2b=$(systemctl is-active fail2ban 2>/dev/null || echo "?")
    after_sync=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "?")
    after_aslr=$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo "?")
    after_core=$(sysctl -n fs.suid_dumpable 2>/dev/null || echo "?")
    after_audit=$(systemctl is-active auditd 2>/dev/null || echo "?")

    _row() { printf '%b│%b %-19s %b│%b %-16s %b│%b %b%-16s%b %b│%b\n' "$CYAN" "$NC" "$1" "$CYAN" "$NC" "$2" "$CYAN" "$NC" "$GREEN" "$3" "$NC" "$CYAN" "$NC" | tee -a "$LOG_FILE"; }
    _row "SSH 端口"        "${BEFORE_STATE[ssh_port]:-?}"     "$after_port"
    _row "密码登录"        "${BEFORE_STATE[ssh_pwd_auth]:-?}" "$after_pwd"
    _row "Root 登录"       "${BEFORE_STATE[ssh_root_login]:-?}" "$after_root"
    _row "防火墙 UFW"      "${BEFORE_STATE[ufw_status]:-?}"   "$after_ufw"
    _row "Fail2ban"        "${BEFORE_STATE[fail2ban]:-?}"      "$after_f2b"
    _row "SYN Cookies"     "${BEFORE_STATE[syncookies]:-?}"    "$after_sync"
    _row "ASLR"            "${BEFORE_STATE[aslr]:-?}"          "$after_aslr"
    _row "核心转储"        "${BEFORE_STATE[core_dump]:-?}"     "$after_core"
    _row "审计 auditd"     "${BEFORE_STATE[auditd]:-?}"       "$after_audit"

    printf '%b└─────────────────────┴──────────────────┴──────────────────┘%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"

    # ── 验证通过率 ──
    echo "" | tee -a "$LOG_FILE"
    printf '  %b验证通过率: %b%d/%d (%d%%)%b\n' "$BOLD" "$GREEN" "$PASS_COUNT" "$TOTAL_COUNT" "$rate" "$NC" | tee -a "$LOG_FILE"

    # ── 你得到了什么 ──
    echo "" | tee -a "$LOG_FILE"
    printf '%b═══ 本次加固为你带来 ═══%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '  %b✓%b SSH 强化: 端口 %s, Ed25519 优先, 限制登录尝试\n' "${GREEN}" "${NC}" "$after_port" | tee -a "$LOG_FILE"
    printf '  %b✓%b 防火墙: UFW 仅放行必要端口, Docker 兼容\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '  %b✓%b 暴力防护: Fail2ban %s次重试/%ss封禁\n' "${GREEN}" "${NC}" "$FAIL2BAN_MAXRETRY" "$FAIL2BAN_BANTIME" | tee -a "$LOG_FILE"
    printf '  %b✓%b 内核加固: SYN cookies, ASLR, ptrace 限制, 禁用危险模块\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '  %b✓%b 文件安全: SUID 清理, /etc/shadow 600, 关键目录加固\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '  %b✓%b 攻击面缩减: 禁用不必要服务, 核心转储, su/shell 限制\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf '  %b✓%b 审计追踪: auditd 全面规则, 自动更新, 登录横幅\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    if [[ "$INSTALL_AIDE" == "yes" ]]; then
        printf '  %b✓%b 完整性检测: AIDE 每日检查\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    fi
    if [[ "$INSTALL_RKHUNTER" == "yes" ]]; then
        printf '  %b✓%b Rootkit 扫描: rkhunter 每周扫描\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    fi

    # ── 生成的文件 ──
    echo "" | tee -a "$LOG_FILE"
    printf '%b═══ 生成的文件 ═══%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf "  日志文件:    %s\n" "$LOG_FILE" | tee -a "$LOG_FILE"
    printf "  诊断报告:    %s\n" "$DIAG_FILE" | tee -a "$LOG_FILE"
    printf "  回滚脚本:    %s\n" "$ROLLBACK_SCRIPT" | tee -a "$LOG_FILE"
    printf "  备份目录:    %s\n" "$BACKUP_DIR" | tee -a "$LOG_FILE"

    # ── 重要提示 ──
    echo "" | tee -a "$LOG_FILE"
    printf '%b⚠ 重要提示:%b\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
    printf '  1. SSH 端口: %b%s%b — 请确保新端口可连接后再断开当前会话\n' "${BOLD}" "$after_port" "${NC}" | tee -a "$LOG_FILE"
    printf '  2. 新SSH连接: %bssh -p %s user@host%b\n' "${BOLD}" "$after_port" "${NC}" | tee -a "$LOG_FILE"
    printf '  3. 如需回滚: %bsudo bash %s%b\n' "${BOLD}" "$ROLLBACK_SCRIPT" "${NC}" | tee -a "$LOG_FILE"
    if [[ "${BEFORE_STATE[docker_count]:-0}" -gt 0 ]]; then
        printf "  4. Docker 容器 (%s个) 不受影响\n" "${BEFORE_STATE[docker_count]}" | tee -a "$LOG_FILE"
    fi
}

###############################################################################
#  主流程
###############################################################################
main() {
    check_root
    check_os

    # 解析参数
    for arg in "$@"; do
        case "$arg" in
            --auto) AUTO_MODE="yes" ;;
            --force) FORCE_MODE="yes" ;;
            --help|-h)
                echo "sec-harden.sh v$SCRIPT_VERSION — Ubuntu 服务器安全加固脚本"
                echo ""
                echo "用法:"
                echo "  sudo bash $0                  # 交互模式"
                echo "  sudo bash $0 --auto           # 自动执行（危险操作仍需确认）"
                echo "  sudo bash $0 --auto --force   # 全自动无交互"
                echo "  SSH_MODE=dev sudo bash $0 --auto  # 开发模式"
                exit 0
                ;;
        esac
    done

    # 初始化
    init_backup
    capture_before_state

    printf '%b' "${BOLD}${GREEN}"
    printf "╔═══════════════════════════════════════════════════════════════╗\n"
    printf '║       Ubuntu 服务器安全加固脚本 sec-harden.sh v%s      ║\n' "$SCRIPT_VERSION"
    printf "╚═══════════════════════════════════════════════════════════════╝\n"
    printf '%b\n' "${NC}"

    # 交互或自动模式
    if [[ "$AUTO_MODE" != "yes" ]]; then
        interactive_menu
    else
        log "INFO" "自动模式启动"
    fi

    log "INFO" "开始安全加固..."
    log "INFO" "SSH_PORT=$SSH_PORT SSH_MODE=$SSH_MODE"

    # 依次执行所有模块
    harden_ssh
    setup_ufw
    setup_fail2ban
    harden_sysctl
    disable_kernel_modules
    clean_suid
    setup_password_policy
    harden_file_permissions
    minimize_services
    setup_auditd
    setup_auto_updates
    disable_core_dumps
    harden_tmp
    restrict_su
    harden_shell
    if [[ "$INSTALL_AIDE" == "yes" ]]; then
        setup_aide
    else
        log "INFO" "跳过 AIDE 安装 (INSTALL_AIDE=$INSTALL_AIDE)"
    fi
    if [[ "$INSTALL_RKHUNTER" == "yes" ]]; then
        setup_rkhunter
    else
        log "INFO" "跳过 rkhunter 安装 (INSTALL_RKHUNTER=$INSTALL_RKHUNTER)"
    fi
    lockdown_mta

    # 完成回滚脚本
    echo 'echo "=== 回滚完成 ==="' >> "$ROLLBACK_SCRIPT"
    chmod 700 "$ROLLBACK_SCRIPT"

    # 验证
    run_verification

    # 生成报告
    generate_report

    # 显示成果总结
    show_final_summary
}

main "$@"
