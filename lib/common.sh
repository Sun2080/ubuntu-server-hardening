#!/usr/bin/env bash
###############################################################################
#  lib/common.sh — 公共函数库
#  供 init-mirror.sh / sec-harden.sh / web-optimize.sh 共享
#  用法: 在脚本开头 source 此文件
#    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#    # shellcheck source=lib/common.sh
#    source "${SCRIPT_DIR}/lib/common.sh"
###############################################################################

# ─── 颜色与输出 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# 使用 %b 替代直接在格式字符串中嵌入变量，消除 SC2059 警告
log() {
    local level=$1; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
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
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "$NC" | tee -a "$LOG_FILE"
    printf '%b  步骤 %s: %s%b\n' "${BOLD}${CYAN}" "$num" "$*" "$NC" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "$NC" | tee -a "$LOG_FILE"
}

check_result() {
    local desc=$1 result=$2
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$result" == "pass" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '  %b✓%b %s\n' "$GREEN" "$NC" "$desc" | tee -a "$LOG_FILE"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf '  %b✗%b %s\n' "$RED" "$NC" "$desc" | tee -a "$LOG_FILE"
    fi
}

# ─── 前置检查 ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf '%b错误: 请以 root 权限运行此脚本%b\n' "$RED" "$NC" >&2
        echo "用法: sudo bash $0 [--auto] [--force]" >&2
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log "ERROR" "无法检测操作系统"
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log "ERROR" "此脚本仅支持 Ubuntu 系统，当前: $ID"
        exit 1
    fi
    # 版本兼容性预警: 仅在 22.04/24.04 上充分测试
    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *) log "WARN" "此脚本仅在 Ubuntu 22.04/24.04 LTS 上测试，当前: ${VERSION_ID:-unknown}，部分功能可能不兼容" ;;
    esac
}

# ─── 备份框架 ────────────────────────────────────────────────────────────────
backup_file() {
    local src=$1
    if [[ -f "$src" ]]; then
        local dest="${BACKUP_DIR}${src}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$src" "$dest"
        # 在回滚脚本中添加恢复命令（如果 ROLLBACK_SCRIPT 已定义）
        if [[ -n "${ROLLBACK_SCRIPT:-}" ]]; then
            echo "cp -a '${dest}' '${src}' && echo '已恢复: ${src}'" >> "$ROLLBACK_SCRIPT"
        fi
    fi
}

# ─── 危险操作确认 ────────────────────────────────────────────────────────────
# 即使 --auto 也会询问，--force 跳过
confirm_dangerous() {
    local msg=$1
    if [[ "${FORCE_MODE:-no}" == "yes" ]]; then
        log "INFO" "[FORCE] 跳过确认: $msg"
        return 0
    fi
    echo "" | tee -a "$LOG_FILE"
    printf '  %b⚠ 危险操作: %s%b\n' "$YELLOW" "$msg" "$NC" | tee -a "$LOG_FILE"
    printf '  %b确认继续? [y/N]: %b' "$BOLD" "$NC"
    local answer
    read -r answer </dev/tty 2>/dev/null || answer="n"
    case "$answer" in
        [yY]*) return 0 ;;
        *) log "WARN" "用户取消: $msg"; return 1 ;;
    esac
}

# ─── 普通操作确认（默认 Y）────────────────────────────────────────────────────
confirm_action() {
    local msg=$1
    if [[ "${FORCE_MODE:-no}" == "yes" ]]; then
        log "INFO" "[FORCE] 跳过确认: $msg"
        return 0
    fi
    echo "" | tee -a "$LOG_FILE"
    printf '  %b▸ %s%b\n' "$YELLOW" "$msg" "$NC" | tee -a "$LOG_FILE"
    printf '  %b确认继续? [Y/n]: %b' "$BOLD" "$NC"
    local answer
    read -r answer </dev/tty 2>/dev/null || answer="y"
    case "$answer" in
        [nN]*) log "WARN" "用户取消: $msg"; return 1 ;;
        *) return 0 ;;
    esac
}

# ─── 工具函数 ────────────────────────────────────────────────────────────────
get_total_mem_mb() {
    free -m | awk '/Mem:/{print $2}'
}

get_available_mem_mb() {
    free -m | awk '/Mem:/{print $7}'
}

get_cpu_cores() {
    nproc
}
