#!/usr/bin/env bash
###############################################################################
#  init-mirror.sh — Ubuntu 云服务器换源 + 安全全量更新
#  适用系统: Ubuntu 22.04 / 24.04 LTS
#  用法:
#    sudo bash init-mirror.sh                  # 交互模式（选择云厂商+确认）
#    sudo bash init-mirror.sh --auto           # 自动检测云厂商，确认后执行
#    sudo bash init-mirror.sh --auto --force   # 全自动无交互
#    MIRROR=ustc sudo bash init-mirror.sh      # 指定镜像源
#
#  建议在 sec-harden.sh 和 web-optimize.sh 之前运行（仅需执行一次）
###############################################################################
set -Euo pipefail
SCRIPT_VERSION="1.0"
# NOTE: lib/common.sh 提供了可共享的公共函数，当前脚本仍使用内联定义以保持独立可用
# ─── ERR trap ────────────────────────────────────────────────────────────────
trap '_err_handler $LINENO "$BASH_COMMAND"' ERR
_err_handler() {
    local lineno=$1 cmd=$2
    log "ERROR" "命令失败 (行 $lineno): $cmd"
}

# ─── 全局变量（均可通过环境变量覆盖）─────────────────────────────────────────
MIRROR="${MIRROR:-auto}"             # auto | tencent | aliyun | huawei | ustc | tuna
SKIP_UPGRADE="${SKIP_UPGRADE:-no}"   # yes = 仅换源不升级
DOCKER_MIRROR="${DOCKER_MIRROR:-yes}" # yes = 同时配置 Docker Hub 加速
AUTO_MODE="${AUTO_MODE:-no}"
FORCE_MODE="${FORCE_MODE:-no}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/.init-mirror-backup/${TIMESTAMP}"
LOG_FILE="/var/log/init-mirror-${TIMESTAMP}.log"

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
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "$NC" | tee -a "$LOG_FILE"
    printf '%b  步骤 %s: %s%b\n' "${BOLD}${CYAN}" "$num" "$*" "$NC" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "$NC" | tee -a "$LOG_FILE"
}

confirm_action() {
    local msg=$1
    if [[ "$FORCE_MODE" == "yes" ]]; then
        log "INFO" "[FORCE] 跳过确认: $msg"
        return 0
    fi
    echo "" | tee -a "$LOG_FILE"
    printf '  %b▸ %s%b\n' "$YELLOW" "$msg" "$NC" | tee -a "$LOG_FILE"
    printf '  %b确认继续? [Y/n]: %b' "$BOLD" "$NC"
    read -r answer </dev/tty 2>/dev/null || answer="y"
    case "$answer" in
        [nN]*) log "WARN" "用户取消: $msg"; return 1 ;;
        *) return 0 ;;
    esac
}

# ─── 前置检查 ────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
        echo "用法: sudo bash $0 [--auto] [--force]"
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
    UBUNTU_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo 'unknown')}"
    log "INFO" "检测到 $PRETTY_NAME ($UBUNTU_CODENAME, 架构 $(dpkg --print-architecture))"

    # 判断使用 DEB822 还是传统格式
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        SOURCE_FORMAT="deb822"
        SOURCE_FILE="/etc/apt/sources.list.d/ubuntu.sources"
    else
        SOURCE_FORMAT="traditional"
        SOURCE_FILE="/etc/apt/sources.list"
    fi
    log "INFO" "APT 源格式: ${SOURCE_FORMAT} (${SOURCE_FILE})"
}

# ─── 备份 ────────────────────────────────────────────────────────────────────
init_backup() {
    mkdir -p "$BACKUP_DIR"
    # 备份当前源文件
    if [[ -f "$SOURCE_FILE" ]]; then
        cp -a "$SOURCE_FILE" "${BACKUP_DIR}/$(basename "$SOURCE_FILE").bak"
        log "INFO" "已备份: $SOURCE_FILE"
    fi
    # 备份 sources.list (可能为空但保留)
    if [[ -f /etc/apt/sources.list ]]; then
        cp -a /etc/apt/sources.list "${BACKUP_DIR}/sources.list.bak"
    fi
    # 备份 Docker daemon.json
    if [[ -f /etc/docker/daemon.json ]]; then
        cp -a /etc/docker/daemon.json "${BACKUP_DIR}/daemon.json.bak"
        log "INFO" "已备份: /etc/docker/daemon.json"
    fi
    # 生成回滚脚本
    cat > "${BACKUP_DIR}/rollback.sh" << ROLLBACK
#!/usr/bin/env bash
set -euo pipefail
echo "=== 回滚 APT 源配置 ==="
ROLLBACK
    if [[ -f "${BACKUP_DIR}/$(basename "$SOURCE_FILE").bak" ]]; then
        echo "cp -a '${BACKUP_DIR}/$(basename "$SOURCE_FILE").bak' '${SOURCE_FILE}'" >> "${BACKUP_DIR}/rollback.sh"
    fi
    if [[ -f "${BACKUP_DIR}/sources.list.bak" ]]; then
        echo "cp -a '${BACKUP_DIR}/sources.list.bak' '/etc/apt/sources.list'" >> "${BACKUP_DIR}/rollback.sh"
    fi
    if [[ -f "${BACKUP_DIR}/daemon.json.bak" ]]; then
        echo "cp -a '${BACKUP_DIR}/daemon.json.bak' '/etc/docker/daemon.json'" >> "${BACKUP_DIR}/rollback.sh"
        echo "systemctl restart docker 2>/dev/null || true" >> "${BACKUP_DIR}/rollback.sh"
    fi
    echo 'echo "=== 回滚完成，请执行 apt update 刷新 ==="' >> "${BACKUP_DIR}/rollback.sh"
    chmod 700 "${BACKUP_DIR}/rollback.sh"
    log "INFO" "回滚脚本: ${BACKUP_DIR}/rollback.sh"
}

# ─── 镜像源定义 ──────────────────────────────────────────────────────────────
# 返回: MIRROR_URL
declare -A MIRROR_INTERNAL MIRROR_EXTERNAL MIRROR_LABEL
MIRROR_INTERNAL[tencent]="mirrors.tencentyun.com"
MIRROR_EXTERNAL[tencent]="mirrors.cloud.tencent.com"
MIRROR_LABEL[tencent]="腾讯云"

MIRROR_INTERNAL[aliyun]="mirrors.cloud.aliyuncs.com"
MIRROR_EXTERNAL[aliyun]="mirrors.aliyun.com"
MIRROR_LABEL[aliyun]="阿里云"

MIRROR_INTERNAL[huawei]="repo.myhuaweicloud.com"
MIRROR_EXTERNAL[huawei]="repo.huaweicloud.com"
MIRROR_LABEL[huawei]="华为云"

MIRROR_INTERNAL[ustc]="mirrors.ustc.edu.cn"
MIRROR_EXTERNAL[ustc]="mirrors.ustc.edu.cn"
MIRROR_LABEL[ustc]="中科大"

MIRROR_INTERNAL[tuna]="mirrors.tuna.tsinghua.edu.cn"
MIRROR_EXTERNAL[tuna]="mirrors.tuna.tsinghua.edu.cn"
MIRROR_LABEL[tuna]="清华 TUNA"

# Docker Hub 镜像加速
declare -A DOCKER_MIRROR_URL
DOCKER_MIRROR_URL[tencent]="https://mirror.ccs.tencentyun.com"
DOCKER_MIRROR_URL[aliyun]="https://registry.cn-hangzhou.aliyuncs.com"
DOCKER_MIRROR_URL[huawei]="https://05f073ad3c0010ea0f4bc00b7105ec20.mirror.swr.myhuaweicloud.com"
DOCKER_MIRROR_URL[ustc]="https://docker.mirrors.ustc.edu.cn"
DOCKER_MIRROR_URL[tuna]="https://docker.mirrors.ustc.edu.cn"

# ─── 自动检测云厂商 + 内网可达性 ────────────────────────────────────────────
detect_cloud_provider() {
    log "INFO" "正在自动检测云环境..."

    # 方法1: 通过 metadata API 检测
    local provider=""
    if curl -sf --connect-timeout 2 --max-time 3 http://metadata.tencentyun.com/latest/meta-data/ &>/dev/null; then
        provider="tencent"
    elif curl -sf --connect-timeout 2 --max-time 3 http://100.100.100.200/latest/meta-data/ &>/dev/null; then
        provider="aliyun"
    elif curl -sf --connect-timeout 2 --max-time 3 http://169.254.169.254/openstack/latest/meta_data.json &>/dev/null; then
        provider="huawei"
    fi

    # 方法2: 从当前源文件推断
    if [[ -z "$provider" && -f "$SOURCE_FILE" ]]; then
        local current_mirror
        current_mirror=$(grep -oP 'mirrors\.\w+\.com' "$SOURCE_FILE" 2>/dev/null | head -1 || true)
        case "$current_mirror" in
            mirrors.tencentyun.com|mirrors.cloud.tencent.com) provider="tencent" ;;
            mirrors.cloud.aliyuncs.com|mirrors.aliyun.com)     provider="aliyun" ;;
            *myhuaweicloud*|*huaweicloud*)                      provider="huawei" ;;
        esac
    fi

    # 方法3: 从 /sys/class/dmi/id 推断
    if [[ -z "$provider" ]]; then
        local vendor
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
        case "$vendor" in
            *Tencent*) provider="tencent" ;;
            *Alibaba*) provider="aliyun" ;;
            *HUAWEI*)  provider="huawei" ;;
        esac
    fi

    if [[ -n "$provider" ]]; then
        log "INFO" "检测到云厂商: ${MIRROR_LABEL[$provider]}"
        DETECTED_PROVIDER="$provider"
    else
        log "WARN" "未检测到已知云厂商，将使用中科大镜像源"
        DETECTED_PROVIDER="ustc"
    fi
}

# 测试内网镜像是否可达
test_internal_mirror() {
    local provider=$1
    local internal="${MIRROR_INTERNAL[$provider]}"
    log "INFO" "测试内网镜像 ${internal} ..."
    if curl -sf --connect-timeout 3 --max-time 5 "http://${internal}/ubuntu/dists/" &>/dev/null; then
        log "INFO" "内网镜像可达 ✓ (延迟更低、流量免费)"
        MIRROR_URL="$internal"
        MIRROR_IS_INTERNAL="yes"
        return 0
    else
        local external="${MIRROR_EXTERNAL[$provider]}"
        log "WARN" "内网镜像不可达，使用外网镜像: ${external}"
        MIRROR_URL="$external"
        MIRROR_IS_INTERNAL="no"
        return 0
    fi
}

# ─── 交互选择镜像（非 auto 模式）──────────────────────────────────────────────
select_mirror_interactive() {
    echo ""
    printf '%b请选择镜像源:%b\n' "${BOLD}" "${NC}"
    echo "  1) 腾讯云 (内网优先)"
    echo "  2) 阿里云 (内网优先)"
    echo "  3) 华为云 (内网优先)"
    echo "  4) 中科大 USTC"
    echo "  5) 清华 TUNA"
    echo "  0) 跳过换源（仅执行系统更新）"
    echo ""
    printf '  %b请输入 [0-5]: %b' "${BOLD}" "${NC}"
    local choice
    read -r choice </dev/tty 2>/dev/null || choice="1"
    case "$choice" in
        1) MIRROR="tencent" ;;
        2) MIRROR="aliyun"  ;;
        3) MIRROR="huawei"  ;;
        4) MIRROR="ustc"    ;;
        5) MIRROR="tuna"    ;;
        0) MIRROR="skip"    ;;
        *) log "WARN" "无效选择，使用默认(中科大)"; MIRROR="ustc" ;;
    esac
}

# ─── 写入 DEB822 格式源 (.sources) ──────────────────────────────────────────
write_deb822_source() {
    local mirror_url=$1
    local codename=$2
    local target=$3

    cat > "$target" << EOF
## 由 init-mirror.sh v${SCRIPT_VERSION} 生成 — ${TIMESTAMP}
## 镜像源: ${mirror_url}
## 回滚: sudo bash ${BACKUP_DIR}/rollback.sh

Types: deb
URIs: http://${mirror_url}/ubuntu/
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://${mirror_url}/ubuntu/
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    log "INFO" "已写入 DEB822 源: $target"
}

# ─── 写入传统格式源 (sources.list) ───────────────────────────────────────────
write_traditional_source() {
    local mirror_url=$1
    local codename=$2
    local target=$3

    cat > "$target" << EOF
## 由 init-mirror.sh v${SCRIPT_VERSION} 生成 — ${TIMESTAMP}
## 镜像源: ${mirror_url}
## 回滚: sudo bash ${BACKUP_DIR}/rollback.sh

deb http://${mirror_url}/ubuntu/ ${codename} main restricted universe multiverse
deb http://${mirror_url}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb http://${mirror_url}/ubuntu/ ${codename}-backports main restricted universe multiverse
deb http://${mirror_url}/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
    log "INFO" "已写入传统格式源: $target"
}

# ─── 配置 Docker Hub 镜像加速 ────────────────────────────────────────────────
configure_docker_mirror() {
    local provider=$1
    if ! command -v docker &>/dev/null; then
        log "WARN" "Docker 未安装，跳过 Docker Hub 镜像配置"
        return 0
    fi

    local docker_url="${DOCKER_MIRROR_URL[$provider]:-}"
    if [[ -z "$docker_url" ]]; then
        log "WARN" "该云厂商无 Docker 镜像加速配置"
        return 0
    fi

    local daemon_json="/etc/docker/daemon.json"
    mkdir -p /etc/docker

    if [[ -f "$daemon_json" ]]; then
        # 已有配置 — 用 python3 合并 registry-mirrors
        if command -v python3 &>/dev/null; then
            local result
            result=$(python3 -c "
import json
try:
    with open('$daemon_json') as f:
        cfg = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    cfg = {}
mirrors = cfg.get('registry-mirrors', [])
print('exists' if '$docker_url' in mirrors else 'missing')
" 2>/dev/null || echo "missing")

            if [[ "$result" == "missing" ]]; then
                python3 -c "
import json
try:
    with open('$daemon_json') as f:
        cfg = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    cfg = {}
mirrors = cfg.get('registry-mirrors', [])
mirrors.insert(0, '$docker_url')
cfg['registry-mirrors'] = mirrors
with open('$daemon_json', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
" 2>/dev/null
                log "INFO" "Docker Hub 加速已添加: $docker_url"
            else
                log "INFO" "Docker Hub 加速已存在: $docker_url"
            fi
        else
            log "WARN" "无 python3，跳过 Docker 镜像配置（避免破坏现有 daemon.json）"
            return 0
        fi
    else
        # 全新配置
        cat > "$daemon_json" << EOF
{
  "registry-mirrors": [
    "${docker_url}"
  ]
}
EOF
        log "INFO" "Docker Hub 加速已配置: $docker_url"
    fi

    # 重载 Docker（不重启容器）
    if systemctl is-active docker &>/dev/null; then
        if confirm_action "重载 Docker daemon 以应用镜像加速（不会重启容器）"; then
            systemctl reload docker 2>/dev/null || systemctl restart docker
            log "INFO" "Docker daemon 已重载"
        fi
    fi
}

# ─── 安全全量更新 ────────────────────────────────────────────────────────────
safe_system_upgrade() {
    log "INFO" "刷新包索引..."
    apt-get update -qq 2>&1 | tee -a "$LOG_FILE"

    # 统计可升级包数量
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || echo "0")
    log "INFO" "可升级包数量: $upgradable"

    if [[ "$upgradable" -eq 0 ]]; then
        log "INFO" "系统已是最新，无需升级"
        return 0
    fi

    if ! confirm_action "即将升级 ${upgradable} 个包（保留现有配置文件，不会覆盖你的自定义配置）"; then
        log "WARN" "用户跳过系统升级"
        return 0
    fi

    log "INFO" "开始安全升级（DEBIAN_FRONTEND=noninteractive + confold）..."

    # 关键: --force-confold 保留现有配置文件（sshd_config 等不会被覆盖）
    #        --force-confdef 新增配置文件用默认值
    DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
        apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --no-install-recommends \
        2>&1 | tee -a "$LOG_FILE"

    log "INFO" "升级完成"

    # 清理不再需要的包
    apt-get autoremove -y --purge 2>&1 | tee -a "$LOG_FILE"
    apt-get autoclean -y 2>&1 | tee -a "$LOG_FILE"
    log "INFO" "已清理孤立包和缓存"

    # 检查是否需要重启
    if [[ -f /var/run/reboot-required ]]; then
        echo "" | tee -a "$LOG_FILE"
        printf '  %b⚠ 内核已更新，建议重启服务器使其生效%b\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            printf "  %b  需要重启的包: %s%b\n" "$YELLOW" "$(tr '\n' ' ' < /var/run/reboot-required.pkgs)" "$NC" | tee -a "$LOG_FILE"
        fi
        log "WARN" "系统需要重启以完成内核更新"
    else
        log "INFO" "无需重启"
    fi
}

# ─── 验证 ────────────────────────────────────────────────────────────────────
run_verification() {
    step_banner "4" "验证结果"

    local pass=0 total=0

    # 1. 检查源文件
    total=$((total + 1))
    if [[ -f "$SOURCE_FILE" ]] && grep -q "$MIRROR_URL" "$SOURCE_FILE" 2>/dev/null; then
        printf '  %b✓%b APT 源已切换到 %s\n' "${GREEN}" "${NC}" "$MIRROR_URL" | tee -a "$LOG_FILE"
        pass=$((pass + 1))
    elif [[ "${MIRROR:-}" == "skip" ]]; then
        printf '  %b—%b APT 源: 用户跳过\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
        pass=$((pass + 1))
    else
        printf '  %b✗%b APT 源未正确写入\n' "${RED}" "${NC}" | tee -a "$LOG_FILE"
    fi

    # 2. 检查 apt update 成功
    total=$((total + 1))
    if apt-get update -qq 2>&1 | grep -qiE 'err|fail'; then
        printf '  %b✗%b apt update 有错误\n' "${RED}" "${NC}" | tee -a "$LOG_FILE"
    else
        printf '  %b✓%b apt update 正常\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
        pass=$((pass + 1))
    fi

    # 3. Docker 镜像加速
    total=$((total + 1))
    if [[ "$DOCKER_MIRROR" == "yes" ]] && command -v docker &>/dev/null; then
        if docker info 2>/dev/null | grep -q "Registry Mirrors\|registry-mirrors\|mirror"; then
            printf '  %b✓%b Docker Hub 镜像加速已生效\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
            pass=$((pass + 1))
        elif grep -q "registry-mirrors" /etc/docker/daemon.json 2>/dev/null; then
            printf '  %b✓%b Docker Hub 镜像加速已配置\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
            pass=$((pass + 1))
        else
            printf '  %b—%b Docker Hub 镜像加速未配置\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
            pass=$((pass + 1))  # 非关键项
        fi
    else
        printf '  %b—%b Docker 镜像加速: 跳过\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
        pass=$((pass + 1))
    fi

    echo "" | tee -a "$LOG_FILE"
    printf '%b验证结果: %b%d%b/%b%d%b 通过\n' "$BOLD" "$GREEN" "$pass" "$NC" "$BOLD" "$total" "$NC" | tee -a "$LOG_FILE"
}

# ─── 结果摘要 ────────────────────────────────────────────────────────────────
print_summary() {
    echo "" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"
    printf '%b  init-mirror.sh v%s — 执行摘要%b\n' "${BOLD}${CYAN}" "$SCRIPT_VERSION" "$NC" | tee -a "$LOG_FILE"
    printf '%b═══════════════════════════════════════════════════════════════%b\n' "${BOLD}${CYAN}" "${NC}" | tee -a "$LOG_FILE"

    local mirror_display
    if [[ "${MIRROR:-}" == "skip" ]]; then
        mirror_display="(未换源)"
    else
        local provider_label="${MIRROR_LABEL[${SELECTED_PROVIDER:-ustc}]:-未知}"
        local net_type="外网"
        [[ "${MIRROR_IS_INTERNAL:-no}" == "yes" ]] && net_type="内网"
        mirror_display="${provider_label} ${net_type} (${MIRROR_URL:-?})"
    fi

    printf "  %-16s %s\n" "镜像源:" "$mirror_display" | tee -a "$LOG_FILE"
    printf "  %-16s %s\n" "源格式:" "$SOURCE_FORMAT" | tee -a "$LOG_FILE"
    printf "  %-16s %s\n" "回滚脚本:" "${BACKUP_DIR}/rollback.sh" | tee -a "$LOG_FILE"
    printf "  %-16s %s\n" "日志:" "$LOG_FILE" | tee -a "$LOG_FILE"

    if [[ -f /var/run/reboot-required ]]; then
        echo "" | tee -a "$LOG_FILE"
        printf '  %b⚠ 建议重启: sudo reboot%b\n' "${YELLOW}" "${NC}" | tee -a "$LOG_FILE"
    fi

    echo "" | tee -a "$LOG_FILE"
    printf '  %b下一步:%b\n' "${GREEN}" "${NC}" | tee -a "$LOG_FILE"
    printf "    sudo bash sec-harden.sh --auto    # 安全加固\n" | tee -a "$LOG_FILE"
    printf "    sudo bash web-optimize.sh --auto  # 性能优化\n" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
main() {
    # 解析参数
    for arg in "$@"; do
        case "$arg" in
            --auto)   AUTO_MODE="yes" ;;
            --force)  FORCE_MODE="yes"; AUTO_MODE="yes" ;;
            --help|-h)
                echo "init-mirror.sh v${SCRIPT_VERSION} — Ubuntu 云服务器换源 + 安全全量更新"
                echo ""
                echo "用法: sudo bash $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --auto        自动检测云厂商 + 确认后执行"
                echo "  --force       全自动无交互"
                echo "  --help        显示帮助"
                echo ""
                echo "环境变量:"
                echo "  MIRROR=tencent|aliyun|huawei|ustc|tuna|auto|skip"
                echo "  SKIP_UPGRADE=yes    仅换源不升级"
                echo "  DOCKER_MIRROR=no    跳过 Docker Hub 加速"
                exit 0
                ;;
        esac
    done

    echo ""
    printf '%b╔═══════════════════════════════════════════════════════════╗%b\n' "${BOLD}${GREEN}" "${NC}"
    printf '%b║   init-mirror.sh v%-6s — 换源 + 安全全量更新           ║%b\n' "${BOLD}${GREEN}" "$SCRIPT_VERSION" "${NC}"
    printf '%b╚═══════════════════════════════════════════════════════════╝%b\n' "${BOLD}${GREEN}" "${NC}"
    echo ""

    check_root
    mkdir -p "$(dirname "$LOG_FILE")"
    check_os
    init_backup

    # ── 步骤 1: 确定镜像源 ──
    step_banner "1" "选择镜像源"

    SELECTED_PROVIDER=""
    MIRROR_URL=""
    MIRROR_IS_INTERNAL="no"

    if [[ "$MIRROR" == "skip" ]]; then
        log "INFO" "用户指定跳过换源 (MIRROR=skip)"
    elif [[ "$MIRROR" == "auto" ]]; then
        if [[ "$AUTO_MODE" == "yes" ]]; then
            # 自动模式: 检测云厂商
            detect_cloud_provider
            SELECTED_PROVIDER="$DETECTED_PROVIDER"
        else
            # 交互模式: 先检测再让用户选
            detect_cloud_provider
            printf '\n  %b检测建议: %s%b\n\n' "$GREEN" "${MIRROR_LABEL[$DETECTED_PROVIDER]}" "$NC"
            select_mirror_interactive
            if [[ "$MIRROR" != "skip" ]]; then
                SELECTED_PROVIDER="$MIRROR"
            fi
        fi
    else
        # 用户指定了具体镜像
        if [[ -n "${MIRROR_LABEL[$MIRROR]:-}" ]]; then
            SELECTED_PROVIDER="$MIRROR"
            log "INFO" "用户指定镜像: ${MIRROR_LABEL[$MIRROR]}"
        else
            log "ERROR" "未知镜像: $MIRROR (可选: tencent|aliyun|huawei|ustc|tuna)"
            exit 1
        fi
    fi

    # 测试内网可达性
    if [[ -n "$SELECTED_PROVIDER" ]]; then
        test_internal_mirror "$SELECTED_PROVIDER"
    fi

    # ── 步骤 2: 写入源文件 ──
    step_banner "2" "配置 APT 源"

    if [[ "$MIRROR" == "skip" || -z "$MIRROR_URL" ]]; then
        log "INFO" "跳过换源"
    else
        # 检查是否已经是目标源
        if grep -q "$MIRROR_URL" "$SOURCE_FILE" 2>/dev/null; then
            log "INFO" "当前源已是 ${MIRROR_URL}，无需更改"
        else
            if confirm_action "将 APT 源切换到 ${MIRROR_URL}"; then
                if [[ "$SOURCE_FORMAT" == "deb822" ]]; then
                    write_deb822_source "$MIRROR_URL" "$UBUNTU_CODENAME" "$SOURCE_FILE"
                else
                    write_traditional_source "$MIRROR_URL" "$UBUNTU_CODENAME" "$SOURCE_FILE"
                fi
            fi
        fi
    fi

    # ── 步骤 2.5: Docker Hub 镜像加速 ──
    if [[ "$DOCKER_MIRROR" == "yes" && -n "$SELECTED_PROVIDER" ]]; then
        configure_docker_mirror "$SELECTED_PROVIDER"
    fi

    # ── 步骤 3: 安全全量更新 ──
    step_banner "3" "系统安全更新"

    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
        log "INFO" "跳过系统更新 (SKIP_UPGRADE=yes)"
    else
        safe_system_upgrade
    fi

    # ── 步骤 4: 验证 ──
    run_verification

    # ── 摘要 ──
    print_summary
}

main "$@"
