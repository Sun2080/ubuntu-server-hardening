#!/usr/bin/env bash
###############################################################################
#  web-optimize.sh — Web 服务器性能优化脚本
#  适用系统: Ubuntu 22.04 / 24.04 LTS (Docker 容器化环境)
#  用法:
#    sudo bash web-optimize.sh            # 交互模式
#    sudo bash web-optimize.sh --auto     # 自动全量
#    sudo bash web-optimize.sh --dry-run  # 仅生成配置不应用
###############################################################################
set -Euo pipefail

trap '_err_handler $LINENO "$BASH_COMMAND"' ERR
_err_handler() {
    local lineno=$1 cmd=$2
    log "ERROR" "命令失败 (行 $lineno): $cmd"
}

# ─── 全局变量（均可通过环境变量覆盖）─────────────────────────────────────────
AUTO_MODE="${AUTO_MODE:-no}"
DRY_RUN="${DRY_RUN:-no}"

# 系统级
SYSCTL_SOMAXCONN="${SYSCTL_SOMAXCONN:-65535}"
SYSCTL_BACKLOG="${SYSCTL_BACKLOG:-65536}"
SYSCTL_FILE_MAX="${SYSCTL_FILE_MAX:-2097152}"
ULIMIT_NOFILE="${ULIMIT_NOFILE:-1048576}"
SWAPPINESS="${SWAPPINESS:-10}"
DIRTY_RATIO="${DIRTY_RATIO:-15}"
DIRTY_BG_RATIO="${DIRTY_BG_RATIO:-5}"
VFS_CACHE_PRESSURE="${VFS_CACHE_PRESSURE:-50}"
MIN_FREE_KBYTES="${MIN_FREE_KBYTES:-65536}"

# Nginx/OpenResty
NGINX_WORKER_CONNECTIONS="${NGINX_WORKER_CONNECTIONS:-4096}"
NGINX_KEEPALIVE_TIMEOUT="${NGINX_KEEPALIVE_TIMEOUT:-30}"
NGINX_KEEPALIVE_REQUESTS="${NGINX_KEEPALIVE_REQUESTS:-1000}"
NGINX_CLIENT_MAX_BODY="${NGINX_CLIENT_MAX_BODY:-50M}"
NGINX_GZIP_LEVEL="${NGINX_GZIP_LEVEL:-4}"
NGINX_GZIP_MIN_LEN="${NGINX_GZIP_MIN_LEN:-256}"

# PHP-FPM
PHP_PM_MODE="${PHP_PM_MODE:-dynamic}"
PHP_MAX_REQUESTS="${PHP_MAX_REQUESTS:-500}"
PHP_SLOWLOG_TIMEOUT="${PHP_SLOWLOG_TIMEOUT:-5}"
PHP_OPCACHE_MEMORY="${PHP_OPCACHE_MEMORY:-128}"
PHP_OPCACHE_FILES="${PHP_OPCACHE_FILES:-10000}"
PHP_OPCACHE_REVALIDATE="${PHP_OPCACHE_REVALIDATE:-60}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-256M}"
PHP_UPLOAD_MAX="${PHP_UPLOAD_MAX:-50M}"

# MariaDB/MySQL
MARIADB_MAX_CONN="${MARIADB_MAX_CONN:-100}"
MARIADB_WAIT_TIMEOUT="${MARIADB_WAIT_TIMEOUT:-600}"
MARIADB_SLOW_QUERY_TIME="${MARIADB_SLOW_QUERY_TIME:-1}"

# Redis
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-}"  # 空=自动计算
REDIS_MAXCLIENTS="${REDIS_MAXCLIENTS:-256}"
REDIS_POLICY="${REDIS_POLICY:-allkeys-lru}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/.web-optimize-backup/${TIMESTAMP}"
OUTPUT_DIR="/opt/server-tuning"
ROLLBACK_SCRIPT="${BACKUP_DIR}/rollback.sh"
LOG_FILE="/var/log/web-optimize-${TIMESTAMP}.log"
DIAG_FILE="/var/log/web-optimize-diag-${TIMESTAMP}.yaml"
APPLY_SCRIPT="${OUTPUT_DIR}/apply-docker-configs.sh"

PASS_COUNT=0; FAIL_COUNT=0; TOTAL_COUNT=0

# ─── 检测到的容器信息 ─────────────────────────────────────────────────────────
NGINX_CONTAINER=""
PHP_CONTAINER=""
MARIADB_CONTAINER=""
REDIS_CONTAINER=""

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
    printf "${color}[%s] [%-5s] %s${NC}\n" "$ts" "$level" "$*" | tee -a "$LOG_FILE"
}

step_banner() {
    local num=$1; shift
    echo "" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}  步骤 %s: %s${NC}\n" "$num" "$*" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

check_result() {
    local desc=$1 result=$2
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$result" == "pass" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "  ${GREEN}✓${NC} %s\n" "$desc" | tee -a "$LOG_FILE"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "  ${RED}✗${NC} %s\n" "$desc" | tee -a "$LOG_FILE"
    fi
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
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
        log "ERROR" "此脚本仅支持 Ubuntu 系统"
        exit 1
    fi
    log "INFO" "检测到 $PRETTY_NAME (内核 $(uname -r))"
}

init_dirs() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$OUTPUT_DIR"/{nginx,php,mariadb,redis}
    mkdir -p /opt/scripts

    cat > "$ROLLBACK_SCRIPT" << 'ROLLBACK_HEADER'
#!/usr/bin/env bash
# 自动生成的回滚脚本
set -euo pipefail
echo "=== 开始回滚 Web 优化 ==="
ROLLBACK_HEADER
    chmod 700 "$ROLLBACK_SCRIPT"
    log "INFO" "备份目录: $BACKUP_DIR"
    log "INFO" "配置输出: $OUTPUT_DIR"
}

backup_file() {
    local src=$1
    if [[ -f "$src" ]]; then
        local dest="${BACKUP_DIR}${src}"
        mkdir -p "$(dirname "$dest")"
        cp -a "$src" "$dest"
        echo "cp -a '${dest}' '${src}' && echo '已恢复: ${src}'" >> "$ROLLBACK_SCRIPT"
    fi
}

###############################################################################
#  A1. 内核网络调优
###############################################################################
tune_kernel_network() {
    step_banner "A1" "内核网络调优"

    local sysctl_file="/etc/sysctl.d/99-web-optimize.conf"
    backup_file "$sysctl_file"

    cat > "$sysctl_file" << EOF
# === web-optimize.sh 内核网络调优 ===

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216

# 连接队列
net.core.somaxconn = ${SYSCTL_SOMAXCONN}
net.core.netdev_max_backlog = ${SYSCTL_BACKLOG}
net.ipv4.tcp_max_syn_backlog = 65536

# TIME_WAIT 优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# Keepalive 优化
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 本地端口范围
net.ipv4.ip_local_port_range = 1024 65535

# 其他优化
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
EOF

    if [[ "$DRY_RUN" != "yes" ]]; then
        # 处理 /etc/sysctl.conf 中的冲突项（sysctl.conf 加载优先级最高会覆盖 .d/ 下的配置）
        local conflicts=("net.core.somaxconn" "net.ipv4.tcp_max_tw_buckets" "net.ipv4.tcp_slow_start_after_idle")
        for key in "${conflicts[@]}"; do
            if grep -qE "^${key}" /etc/sysctl.conf 2>/dev/null; then
                sed -i "s|^${key}|# ${key}|" /etc/sysctl.conf
                log "INFO" "已注释 /etc/sysctl.conf 中的冲突项: $key (由 99-web-optimize.conf 管理)"
            fi
        done
        sysctl --system >/dev/null 2>&1
        log "INFO" "内核网络参数已应用 (BBR, TCP优化, somaxconn=$SYSCTL_SOMAXCONN)"
    else
        log "INFO" "[DRY-RUN] 已生成内核网络配置: $sysctl_file"
    fi

    echo "rm -f '$sysctl_file' && sysctl --system >/dev/null 2>&1 && echo '已移除网络调优'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  A2. 文件描述符
###############################################################################
tune_file_descriptors() {
    step_banner "A2" "文件描述符优化"

    # fs.file-max
    local sysctl_fd="/etc/sysctl.d/99-web-optimize-fd.conf"
    backup_file "$sysctl_fd"
    cat > "$sysctl_fd" << EOF
# web-optimize.sh: 文件描述符
fs.file-max = ${SYSCTL_FILE_MAX}
fs.nr_open = ${SYSCTL_FILE_MAX}
EOF

    # limits.conf
    local limits_file="/etc/security/limits.d/99-web-optimize.conf"
    backup_file "$limits_file"
    cat > "$limits_file" << EOF
# web-optimize.sh: 文件描述符限制
*           soft    nofile    ${ULIMIT_NOFILE}
*           hard    nofile    ${ULIMIT_NOFILE}
root        soft    nofile    ${ULIMIT_NOFILE}
root        hard    nofile    ${ULIMIT_NOFILE}
EOF

    # systemd DefaultLimitNOFILE
    local systemd_conf="/etc/systemd/system.conf.d"
    mkdir -p "$systemd_conf"
    local systemd_file="$systemd_conf/99-web-optimize.conf"
    backup_file "$systemd_file"
    cat > "$systemd_file" << EOF
[Manager]
DefaultLimitNOFILE=${ULIMIT_NOFILE}
DefaultLimitNPROC=${ULIMIT_NOFILE}
EOF

    if [[ "$DRY_RUN" != "yes" ]]; then
        sysctl --system >/dev/null 2>&1
        systemctl daemon-reload 2>/dev/null || true
        log "INFO" "文件描述符: file-max=$SYSCTL_FILE_MAX, nofile=$ULIMIT_NOFILE"
    else
        log "INFO" "[DRY-RUN] 已生成文件描述符配置"
    fi

    echo "rm -f '$sysctl_fd' '$limits_file' '$systemd_file' && sysctl --system >/dev/null 2>&1 && echo '已移除文件描述符配置'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  A3. 内存策略
###############################################################################
tune_memory() {
    step_banner "A3" "内存策略优化"

    local sysctl_mem="/etc/sysctl.d/99-web-optimize-mem.conf"
    backup_file "$sysctl_mem"
    cat > "$sysctl_mem" << EOF
# web-optimize.sh: 内存策略
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.dirty_background_ratio = ${DIRTY_BG_RATIO}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
vm.min_free_kbytes = ${MIN_FREE_KBYTES}
vm.overcommit_memory = 1
EOF

    if [[ "$DRY_RUN" != "yes" ]]; then
        sysctl --system >/dev/null 2>&1
        log "INFO" "内存策略: swappiness=$SWAPPINESS, dirty_ratio=$DIRTY_RATIO"
    else
        log "INFO" "[DRY-RUN] 已生成内存策略配置"
    fi

    echo "rm -f '$sysctl_mem' && sysctl --system >/dev/null 2>&1 && echo '已移除内存策略'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  A4. 禁用不必要服务释放内存
###############################################################################
disable_unnecessary_services() {
    step_banner "A4" "禁用不必要服务"

    local services=(ModemManager upower udisks2)
    for svc in "${services[@]}"; do
        if systemctl is-active "$svc" &>/dev/null; then
            if [[ "$DRY_RUN" != "yes" ]]; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                log "INFO" "已禁用: $svc"
                echo "systemctl enable '$svc' 2>/dev/null && echo '已恢复: $svc'" >> "$ROLLBACK_SCRIPT"
            else
                log "INFO" "[DRY-RUN] 将禁用: $svc"
            fi
        else
            log "INFO" "$svc 未运行或已禁用"
        fi
    done
}

###############################################################################
#  B5. Docker 容器自动检测
###############################################################################
detect_containers() {
    step_banner "B5" "Docker 容器自动检测"

    if ! command -v docker &>/dev/null; then
        log "WARN" "Docker 未安装，跳过容器检测"
        return
    fi

    if ! docker info &>/dev/null 2>&1; then
        log "WARN" "Docker 未运行，跳过容器检测"
        return
    fi

    local containers
    containers=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null || true)

    if [[ -z "$containers" ]]; then
        log "WARN" "未检测到运行中的 Docker 容器"
        return
    fi

    log "INFO" "正在检测 Docker 容器..."

    while IFS=$'\t' read -r name image; do
        local name_lower="${name,,}"
        local image_lower="${image,,}"

        # OpenResty/Nginx 检测
        if [[ "$image_lower" =~ openresty|nginx ]] || [[ "$name_lower" =~ openresty|nginx ]]; then
            NGINX_CONTAINER="$name"
            log "INFO" "检测到 Nginx/OpenResty 容器: $name (镜像: $image)"
        fi

        # PHP-FPM 检测
        if [[ "$image_lower" =~ php|php-fpm ]] || [[ "$name_lower" =~ php|php-fpm ]]; then
            PHP_CONTAINER="$name"
            log "INFO" "检测到 PHP-FPM 容器: $name (镜像: $image)"
        fi

        # MariaDB/MySQL 检测
        if [[ "$image_lower" =~ mariadb|mysql ]] || [[ "$name_lower" =~ mariadb|mysql ]]; then
            MARIADB_CONTAINER="$name"
            log "INFO" "检测到 MariaDB/MySQL 容器: $name (镜像: $image)"
        fi

        # Redis 检测
        if [[ "$image_lower" =~ redis ]] || [[ "$name_lower" =~ redis ]]; then
            REDIS_CONTAINER="$name"
            log "INFO" "检测到 Redis 容器: $name (镜像: $image)"
        fi
    done <<< "$containers"

    # 打印容器详情
    for container in "$NGINX_CONTAINER" "$PHP_CONTAINER" "$MARIADB_CONTAINER" "$REDIS_CONTAINER"; do
        if [[ -n "$container" ]]; then
            local ports mounts mem
            ports=$(docker port "$container" 2>/dev/null | tr '\n' ', ' || echo "N/A")
            mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null || echo "N/A")
            mem=$(docker stats "$container" --no-stream --format '{{.MemUsage}}' 2>/dev/null || echo "N/A")
            log "INFO" "  $container — 端口: ${ports:-N/A} | 内存: ${mem:-N/A}"
        fi
    done
}

###############################################################################
#  C6-C13: Nginx/OpenResty 优化
###############################################################################
generate_nginx_config() {
    step_banner "C" "Nginx/OpenResty 配置优化"

    local cpu_cores
    cpu_cores=$(get_cpu_cores)

    local nginx_dir="$OUTPUT_DIR/nginx"

    # ─── C6: 主配置 nginx.conf ────────────────────────────────────────────
    cat > "$nginx_dir/nginx.conf" << EOF
# === web-optimize.sh Nginx 主配置 ===
# 生成时间: $(date -Iseconds)
# 系统: $(nproc) 核 CPU, $(get_total_mem_mb)MB 内存

user  www-data;
worker_processes  auto;
worker_cpu_affinity auto;
worker_rlimit_nofile 65535;
pid   /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections  ${NGINX_WORKER_CONNECTIONS};
    multi_accept on;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # === 基础性能 ===
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  ${NGINX_KEEPALIVE_TIMEOUT};
    keepalive_requests ${NGINX_KEEPALIVE_REQUESTS};
    reset_timedout_connection on;

    # === 隐藏版本号 ===
    server_tokens off;
    # more_set_headers 'Server: WebServer';  # 需要 headers-more 模块

    # === 请求限制 ===
    client_max_body_size ${NGINX_CLIENT_MAX_BODY};
    client_body_timeout 15;
    client_header_timeout 15;
    send_timeout 15;
    client_body_buffer_size 128k;
    client_header_buffer_size 4k;
    large_client_header_buffers 4 16k;

    # === C7: Gzip 压缩 ===
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level ${NGINX_GZIP_LEVEL};
    gzip_min_length ${NGINX_GZIP_MIN_LEN};
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/x-javascript
        application/xml
        application/xml+rss
        application/vnd.ms-fontobject
        application/x-font-ttf
        image/svg+xml
        image/x-icon
        font/opentype
        font/woff2;

    # === C8: 静态文件缓存 ===
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # === C9: FastCGI 缓存 ===
    fastcgi_cache_path /var/cache/nginx/fastcgi levels=1:2 keys_zone=FASTCGI:32m max_size=256m inactive=60m;
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";
    fastcgi_cache_use_stale error timeout updating http_500;
    fastcgi_cache_valid 200 301 302 10m;
    fastcgi_cache_valid 404 1m;
    fastcgi_cache_lock on;
    fastcgi_temp_path /var/cache/nginx/fastcgi_temp;

    # === C10: 请求限流 ===
    limit_req_zone \$binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone \$binary_remote_addr zone=login:10m rate=3r/m;
    limit_conn_zone \$binary_remote_addr zone=addr:10m;
    limit_req_status 429;
    limit_conn_status 429;

    # === C13: 日志格式 ===
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for" '
                    'rt=\$request_time uct=\$upstream_connect_time '
                    'urt=\$upstream_response_time';

    access_log /var/log/nginx/access.log main;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    log "INFO" "已生成 nginx.conf (workers=auto, connections=$NGINX_WORKER_CONNECTIONS)"

    # ─── C11: 安全头配置 ──────────────────────────────────────────────────
    cat > "$nginx_dir/security-headers.conf" << 'EOF'
# === web-optimize.sh 安全头配置 ===
# 在 server 块中 include 此文件

# 防止点击劫持
add_header X-Frame-Options "SAMEORIGIN" always;

# 防止 MIME 嗅探
add_header X-Content-Type-Options "nosniff" always;

# XSS 防护
add_header X-XSS-Protection "1; mode=block" always;

# HSTS (仅 HTTPS 站点启用)
# add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

# Referrer 策略
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# 权限策略
add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()" always;

# 禁止嵌入
add_header Content-Security-Policy "frame-ancestors 'self';" always;
EOF

    # ─── C12: 敏感文件拦截 ────────────────────────────────────────────────
    cat > "$nginx_dir/block-sensitive.conf" << 'EOF'
# === web-optimize.sh 敏感文件拦截 ===
# 在 server 块中 include 此文件

# 禁止访问隐藏文件和敏感文件
location ~ /\.(git|env|svn|htaccess|htpasswd|DS_Store) {
    deny all;
    return 404;
}

location ~* \.(sql|bak|old|orig|save|swp|log|sh|py|pl)$ {
    deny all;
    return 404;
}

# 禁止 uploads 目录执行 PHP
location ~* /uploads/.*\.php$ {
    deny all;
    return 403;
}

location ~* /wp-content/uploads/.*\.php$ {
    deny all;
    return 403;
}

# 禁止访问 wp-config.php 等
location = /wp-config.php {
    deny all;
    return 404;
}

# 禁止访问 xmlrpc.php (WordPress 常见攻击向量)
location = /xmlrpc.php {
    deny all;
    return 444;
}
EOF

    # ─── 静态文件缓存配置 ─────────────────────────────────────────────────
    cat > "$nginx_dir/static-cache.conf" << 'EOF'
# === web-optimize.sh 静态文件缓存 ===
# 在 server 块中 include 此文件

# 图片
location ~* \.(jpg|jpeg|png|gif|ico|webp|avif|svg)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    access_log off;
}

# CSS/JS
location ~* \.(css|js)$ {
    expires 7d;
    add_header Cache-Control "public";
    access_log off;
}

# 字体
location ~* \.(woff|woff2|ttf|otf|eot)$ {
    expires 365d;
    add_header Cache-Control "public, immutable";
    add_header Access-Control-Allow-Origin "*";
    access_log off;
}

# 媒体文件
location ~* \.(mp4|webm|mp3|ogg)$ {
    expires 30d;
    add_header Cache-Control "public";
    access_log off;
}
EOF

    # ─── 限流示例 ─────────────────────────────────────────────────────────
    cat > "$nginx_dir/rate-limit-example.conf" << 'EOF'
# === web-optimize.sh 限流示例 ===
# 在 location 块中引用

# 普通请求限流 (10r/s, 突发20)
# limit_req zone=general burst=20 nodelay;
# limit_conn addr 100;

# 登录页限流 (3r/m, 突发5)
# location = /wp-login.php {
#     limit_req zone=login burst=5 nodelay;
#     # ... fastcgi 配置
# }
EOF

    log "INFO" "已生成 Nginx 安全头、敏感文件拦截、静态缓存、限流配置"
}

###############################################################################
#  D14-D17: PHP-FPM 调优
###############################################################################
generate_php_config() {
    step_banner "D" "PHP-FPM 配置优化"

    local total_mem avail_mem max_children start_servers min_spare max_spare
    total_mem=$(get_total_mem_mb)
    avail_mem=$(get_available_mem_mb)

    # 自动计算进程数: 可用内存 × 0.6 ÷ 50MB/进程
    max_children=$(( avail_mem * 60 / 100 / 50 ))
    [[ $max_children -lt 5 ]] && max_children=5
    [[ $max_children -gt 200 ]] && max_children=200

    start_servers=$(( max_children / 4 ))
    [[ $start_servers -lt 2 ]] && start_servers=2

    min_spare=$(( max_children / 4 ))
    [[ $min_spare -lt 2 ]] && min_spare=2

    max_spare=$(( max_children / 2 ))
    [[ $max_spare -lt 4 ]] && max_spare=4

    local php_dir="$OUTPUT_DIR/php"

    # ─── D14: PHP-FPM 进程管理 ────────────────────────────────────────────
    cat > "$php_dir/www.conf" << EOF
; === web-optimize.sh PHP-FPM 进程池配置 ===
; 生成时间: $(date -Iseconds)
; 系统内存: ${total_mem}MB 总量, ${avail_mem}MB 可用

[www]
user = www-data
group = www-data

listen = 0.0.0.0:9000

; 进程管理
pm = ${PHP_PM_MODE}
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests = ${PHP_MAX_REQUESTS}
pm.process_idle_timeout = 10s

; 慢日志
slowlog = /var/log/php-fpm/slow.log
request_slowlog_timeout = ${PHP_SLOWLOG_TIMEOUT}s
request_terminate_timeout = 300s

; 状态页
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

; 错误日志
catch_workers_output = yes
decorate_workers_output = no
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php-fpm/error.log
EOF

    log "INFO" "PHP-FPM 进程: max=$max_children, start=$start_servers, min_spare=$min_spare, max_spare=$max_spare"

    # ─── D15: OPcache ─────────────────────────────────────────────────────
    cat > "$php_dir/opcache.ini" << EOF
; === web-optimize.sh OPcache 配置 ===
[opcache]
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = ${PHP_OPCACHE_MEMORY}
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = ${PHP_OPCACHE_FILES}
opcache.revalidate_freq = ${PHP_OPCACHE_REVALIDATE}
opcache.save_comments = 1
opcache.fast_shutdown = 1
opcache.validate_timestamps = 1
opcache.max_wasted_percentage = 10
opcache.huge_code_pages = 1

; JIT (PHP 8.x)
opcache.jit = 1255
opcache.jit_buffer_size = 64M
EOF

    # ─── D16: PHP 安全配置 ────────────────────────────────────────────────
    cat > "$php_dir/security.ini" << EOF
; === web-optimize.sh PHP 安全配置 ===
[PHP]
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /var/log/php-fpm/php_errors.log
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; 危险函数禁用
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,proc_get_status,proc_close,proc_nice,proc_terminate,pcntl_exec,pcntl_fork,dl

; 资源限制
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = 300
max_input_time = 300
max_input_vars = 3000
post_max_size = ${PHP_UPLOAD_MAX}
upload_max_filesize = ${PHP_UPLOAD_MAX}
max_file_uploads = 20

; 路径安全
open_basedir = /var/www/:/tmp/:/proc/
allow_url_fopen = On
allow_url_include = Off

; 时区
date.timezone = Asia/Shanghai
EOF

    # ─── D17: Session 安全 ────────────────────────────────────────────────
    cat > "$php_dir/session-security.ini" << 'EOF'
; === web-optimize.sh Session 安全 ===
[Session]
session.cookie_httponly = 1
session.cookie_secure = 1
session.use_strict_mode = 1
session.cookie_samesite = Lax
session.use_only_cookies = 1
session.use_trans_sid = 0
session.name = SSID
session.gc_maxlifetime = 3600
session.gc_probability = 1
session.gc_divisor = 1000
session.sid_length = 48
session.sid_bits_per_character = 6
EOF

    log "INFO" "已生成 PHP OPcache、安全配置、Session 配置"
}

###############################################################################
#  E18-E22: MariaDB/MySQL 调优
###############################################################################
generate_mariadb_config() {
    step_banner "E" "MariaDB/MySQL 配置优化"

    local total_mem
    total_mem=$(get_total_mem_mb)

    # InnoDB buffer_pool 自适应计算
    # 小服务器 (<=4GB): 系统内存 × 10%
    # 中型服务器 (4-16GB): 系统内存 × 20%
    # 大型服务器 (>16GB): 系统内存 × 30%
    local buffer_pool_mb
    if [[ $total_mem -le 4096 ]]; then
        buffer_pool_mb=$(( total_mem * 10 / 100 ))
    elif [[ $total_mem -le 16384 ]]; then
        buffer_pool_mb=$(( total_mem * 20 / 100 ))
    else
        buffer_pool_mb=$(( total_mem * 30 / 100 ))
    fi
    [[ $buffer_pool_mb -lt 128 ]] && buffer_pool_mb=128
    [[ $buffer_pool_mb -gt 8192 ]] && buffer_pool_mb=8192

    local mariadb_dir="$OUTPUT_DIR/mariadb"

    cat > "$mariadb_dir/custom.cnf" << EOF
# === web-optimize.sh MariaDB/MySQL 调优 ===
# 生成时间: $(date -Iseconds)
# 系统内存: ${total_mem}MB, buffer_pool: ${buffer_pool_mb}MB

[mysqld]

# === E18: InnoDB 优化 ===
innodb_buffer_pool_size = ${buffer_pool_mb}M
innodb_log_file_size = 128M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_io_capacity = 1000
innodb_io_capacity_max = 2000
innodb_read_io_threads = 4
innodb_write_io_threads = 4
innodb_buffer_pool_instances = 1
innodb_log_buffer_size = 16M
innodb_open_files = 4000

# === E19: 连接管理 ===
max_connections = ${MARIADB_MAX_CONN}
wait_timeout = ${MARIADB_WAIT_TIMEOUT}
interactive_timeout = ${MARIADB_WAIT_TIMEOUT}
connect_timeout = 10
max_allowed_packet = 64M
thread_cache_size = 16
back_log = 128

# === E20: 查询优化 ===
query_cache_type = 1
query_cache_size = 32M
query_cache_limit = 2M
tmp_table_size = 64M
max_heap_table_size = 64M
sort_buffer_size = 2M
join_buffer_size = 2M
read_buffer_size = 1M
read_rnd_buffer_size = 1M
table_open_cache = 2000
table_definition_cache = 2000

# === E21: 慢查询日志 ===
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = ${MARIADB_SLOW_QUERY_TIME}
log_queries_not_using_indexes = 1
log_slow_admin_statements = 1
min_examined_row_limit = 100

# === E22: 安全 ===
local_infile = 0
symbolic-links = 0
skip-name-resolve
sql_mode = STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

# 字符集
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
init_connect = 'SET NAMES utf8mb4'

# 日志
log_error = /var/log/mysql/error.log
expire_logs_days = 7

[client]
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4
EOF

    log "INFO" "MariaDB: buffer_pool=${buffer_pool_mb}M, max_conn=$MARIADB_MAX_CONN, slow_query=${MARIADB_SLOW_QUERY_TIME}s"
}

###############################################################################
#  F23-F25: Redis 优化
###############################################################################
generate_redis_config() {
    step_banner "F" "Redis 配置优化"

    local total_mem
    total_mem=$(get_total_mem_mb)

    # Redis maxmemory: 系统内存的 ~7% 或自定义
    local redis_mem="${REDIS_MAXMEMORY}"
    if [[ -z "$redis_mem" ]]; then
        local redis_mem_mb=$(( total_mem * 7 / 100 ))
        [[ $redis_mem_mb -lt 64 ]] && redis_mem_mb=64
        [[ $redis_mem_mb -gt 1024 ]] && redis_mem_mb=1024
        redis_mem="${redis_mem_mb}mb"
    fi

    local redis_dir="$OUTPUT_DIR/redis"

    cat > "$redis_dir/custom.conf" << EOF
# === web-optimize.sh Redis 优化 ===
# 生成时间: $(date -Iseconds)
# 系统内存: ${total_mem}MB

# === F23: 内存管理 ===
maxmemory ${redis_mem}
maxmemory-policy ${REDIS_POLICY}
maxclients ${REDIS_MAXCLIENTS}

# === F24: 安全 ===
bind 127.0.0.1
protected-mode yes
# rename-command FLUSHALL ""
# rename-command FLUSHDB ""
# rename-command DEBUG ""
# rename-command CONFIG ""
# 注意: 如果通过 1Panel 管理 Redis，不要重命名 CONFIG 命令

# === F25: 性能 ===
tcp-keepalive 300
timeout 0

# 慢日志
slowlog-log-slower-than 10000
slowlog-max-len 128

# 持久化优化
no-appendfsync-on-rewrite yes
rdbchecksum yes

# 内存优化
activerehashing yes
hz 10
dynamic-hz yes
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
replica-lazy-flush yes
EOF

    log "INFO" "Redis: maxmemory=$redis_mem, policy=$REDIS_POLICY, maxclients=$REDIS_MAXCLIENTS"
}

###############################################################################
#  G26: 生成 apply-docker-configs.sh
###############################################################################
generate_apply_script() {
    step_banner "G26" "生成 Docker 配置应用脚本"

    cat > "$APPLY_SCRIPT" << 'HEADER'
#!/usr/bin/env bash
###############################################################################
#  apply-docker-configs.sh — 将优化配置应用到 Docker 容器
#  生成时间: TIMESTAMP_PLACEHOLDER
#  ⚠ 请在执行前审查此脚本内容
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() { printf "${GREEN}[%s] %s${NC}\n" "$(date '+%H:%M:%S')" "$*"; }
warn() { printf "${YELLOW}[%s] ⚠ %s${NC}\n" "$(date '+%H:%M:%S')" "$*"; }
err() { printf "${RED}[%s] ✗ %s${NC}\n" "$(date '+%H:%M:%S')" "$*"; }

BACKUP_DIR="/root/.web-optimize-backup/docker-apply-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup_from_container() {
    local container=$1 src=$2 label=$3
    local dest="$BACKUP_DIR/${container}${src}"
    mkdir -p "$(dirname "$dest")"
    docker cp "$container:$src" "$dest" 2>/dev/null && log "备份: $container:$src -> $dest" || warn "备份失败 (文件可能不存在): $container:$src"
}

HEADER

    sed -i "s/TIMESTAMP_PLACEHOLDER/$(date -Iseconds)/" "$APPLY_SCRIPT"

    # Nginx/OpenResty
    if [[ -n "$NGINX_CONTAINER" ]]; then
        # 检测 1Panel 管理的 OpenResty 配置路径
        local nginx_host_conf=""
        local nginx_host_log=""
        local nginx_host_confd=""
        if [[ -f /opt/1panel/apps/openresty/openresty/conf/nginx.conf ]]; then
            nginx_host_conf="/opt/1panel/apps/openresty/openresty/conf/nginx.conf"
            nginx_host_log="/opt/1panel/apps/openresty/openresty/log"
            nginx_host_confd="/opt/1panel/www/conf.d"
            log "INFO" "检测到 1Panel 管理的 OpenResty，使用宿主机挂载路径"
        fi

        cat >> "$APPLY_SCRIPT" << EOF

# ═══ Nginx/OpenResty: $NGINX_CONTAINER ═══
log "应用 Nginx/OpenResty 配置到容器: $NGINX_CONTAINER"

# 备份原始配置
EOF
        if [[ -n "$nginx_host_conf" ]]; then
            cat >> "$APPLY_SCRIPT" << EOF
cp -a "$nginx_host_conf" "\$BACKUP_DIR/nginx.conf.bak" 2>/dev/null || true

# 复制安全头和敏感文件拦截配置到 conf.d主机目录
# 注意: 主配置 nginx.conf 由 1Panel 管理，不直接覆盖
cp "\$OUTPUT_DIR/nginx/security-headers.conf" "$nginx_host_confd/security-headers.conf" 2>/dev/null || true
cp "\$OUTPUT_DIR/nginx/block-sensitive.conf" "$nginx_host_confd/block-sensitive.conf" 2>/dev/null || true
log "已复制安全头和敏感文件拦截配置到 $nginx_host_confd"

# 重载 OpenResty
docker exec "$NGINX_CONTAINER" nginx -t 2>&1 && docker exec "$NGINX_CONTAINER" nginx -s reload && log "OpenResty 配置已重载" || err "OpenResty 配置验证失败"
EOF
        else
            cat >> "$APPLY_SCRIPT" << EOF
backup_from_container "$NGINX_CONTAINER" "/usr/local/openresty/nginx/conf/nginx.conf" "nginx.conf"

docker exec "$NGINX_CONTAINER" mkdir -p /var/cache/nginx/fastcgi /var/cache/nginx/fastcgi_temp 2>/dev/null || true
docker cp "\$OUTPUT_DIR/nginx/security-headers.conf" "$NGINX_CONTAINER:/usr/local/openresty/nginx/conf/conf.d/security-headers.conf"
docker cp "\$OUTPUT_DIR/nginx/block-sensitive.conf" "$NGINX_CONTAINER:/usr/local/openresty/nginx/conf/conf.d/block-sensitive.conf"

if docker exec "$NGINX_CONTAINER" nginx -t 2>&1; then
    docker exec "$NGINX_CONTAINER" nginx -s reload
    log "Nginx 配置已应用并重载"
else
    err "Nginx 配置验证失败，请检查配置文件"
fi
EOF
        fi
    fi

    # PHP-FPM
    if [[ -n "$PHP_CONTAINER" ]]; then
        # 检测 1Panel 管理的 PHP-FPM 配置路径
        local php_host_confd=""
        local php_host_fpm_conf=""
        if [[ -d /opt/1panel/runtime/php/PHP/conf/conf.d ]]; then
            php_host_confd="/opt/1panel/runtime/php/PHP/conf/conf.d"
            php_host_fpm_conf="/opt/1panel/runtime/php/PHP/conf/php-fpm.conf"
            log "INFO" "检测到 1Panel 管理的 PHP-FPM，使用宿主机挂载路径"
        fi

        # 检测 PHP www.conf 在容器内的实际路径
        local php_fpm_conf
        php_fpm_conf=$(docker exec "$PHP_CONTAINER" sh -c 'find /usr/local/etc/php-fpm.d /etc/php-fpm.d /etc/php /usr/local/etc -name "www.conf" -type f 2>/dev/null | head -1' 2>/dev/null || echo "/usr/local/etc/php-fpm.d/www.conf")
        local php_conf_dir
        php_conf_dir=$(docker exec "$PHP_CONTAINER" sh -c 'php -i 2>/dev/null | grep "Scan this dir" | head -1 | awk -F"=>" "{print \$2}" | xargs' 2>/dev/null || echo "/usr/local/etc/php/conf.d")

        cat >> "$APPLY_SCRIPT" << EOF

# ═══ PHP-FPM: $PHP_CONTAINER ═══
log "应用 PHP-FPM 配置到容器: $PHP_CONTAINER"
EOF
        if [[ -n "$php_host_confd" ]]; then
            cat >> "$APPLY_SCRIPT" << EOF

# 1Panel 管理的 PHP-FPM: 通过宿主机挂载目录复制配置
cp -a "$php_host_confd" "\$BACKUP_DIR/php-conf.d.bak" 2>/dev/null || true
cp "\$OUTPUT_DIR/php/opcache.ini" "$php_host_confd/99-opcache.ini"
cp "\$OUTPUT_DIR/php/security.ini" "$php_host_confd/99-security.ini"
cp "\$OUTPUT_DIR/php/session-security.ini" "$php_host_confd/99-session.ini"
log "PHP 配置已复制到 $php_host_confd"

# 重启 PHP-FPM 容器
docker restart "$PHP_CONTAINER"
log "PHP-FPM 容器已重启"
EOF
        else
            cat >> "$APPLY_SCRIPT" << EOF

backup_from_container "$PHP_CONTAINER" "$php_fpm_conf" "www.conf"
backup_from_container "$PHP_CONTAINER" "$php_conf_dir" "conf.d"
docker exec "$PHP_CONTAINER" mkdir -p /var/log/php-fpm 2>/dev/null || true
docker cp "\$OUTPUT_DIR/php/www.conf" "$PHP_CONTAINER:$php_fpm_conf"
docker cp "\$OUTPUT_DIR/php/opcache.ini" "$PHP_CONTAINER:$php_conf_dir/99-opcache.ini"
docker cp "\$OUTPUT_DIR/php/security.ini" "$PHP_CONTAINER:$php_conf_dir/99-security.ini"
docker cp "\$OUTPUT_DIR/php/session-security.ini" "$PHP_CONTAINER:$php_conf_dir/99-session.ini"
docker restart "$PHP_CONTAINER"
log "PHP-FPM 配置已应用并重启容器"
EOF
        fi
    fi

    # MariaDB/MySQL
    if [[ -n "$MARIADB_CONTAINER" ]]; then
        # 检测 1Panel 管理的 MariaDB 配置路径
        local mariadb_host_conf=""
        if [[ -f /opt/1panel/apps/mariadb/mariadb/conf/my.cnf ]]; then
            mariadb_host_conf="/opt/1panel/apps/mariadb/mariadb/conf/my.cnf"
            log "INFO" "检测到 1Panel 管理的 MariaDB，使用宿主机配置路径"
        fi

        cat >> "$APPLY_SCRIPT" << EOF

# ═══ MariaDB: $MARIADB_CONTAINER ═══
log "应用 MariaDB 配置到容器: $MARIADB_CONTAINER"
EOF
        if [[ -n "$mariadb_host_conf" ]]; then
            cat >> "$APPLY_SCRIPT" << EOF

# 1Panel 管理的 MariaDB: 将优化配置追加到宿主机 my.cnf
cp -a "$mariadb_host_conf" "\$BACKUP_DIR/mariadb-my.cnf.bak" 2>/dev/null || true

# 将生成的优化配置以 !includedir 方式引入
mkdir -p /opt/1panel/apps/mariadb/mariadb/conf/conf.d
cp "\$OUTPUT_DIR/mariadb/custom.cnf" "/opt/1panel/apps/mariadb/mariadb/conf/conf.d/zz-optimize.cnf"

# 检查 my.cnf 是否已包含 includedir
if ! grep -q 'includedir.*conf.d' "$mariadb_host_conf" 2>/dev/null; then
    echo '' >> "$mariadb_host_conf"
    echo '!includedir /etc/mysql/conf.d/' >> "$mariadb_host_conf"
    log "已添加 includedir 到 my.cnf"
fi

# 重启 MariaDB 容器
docker restart "$MARIADB_CONTAINER"
log "MariaDB 配置已应用并重启容器"
EOF
        else
            local mysql_conf_path
            mysql_conf_path=$(docker exec "$MARIADB_CONTAINER" sh -c 'find /etc/mysql/conf.d /etc/mysql/mariadb.conf.d /etc/my.cnf.d -type d 2>/dev/null | head -1' 2>/dev/null || echo "/etc/mysql/conf.d")
            cat >> "$APPLY_SCRIPT" << EOF

backup_from_container "$MARIADB_CONTAINER" "$mysql_conf_path" "conf.d"
docker exec "$MARIADB_CONTAINER" mkdir -p /var/log/mysql 2>/dev/null || true
docker exec "$MARIADB_CONTAINER" chown mysql:mysql /var/log/mysql 2>/dev/null || true
docker cp "\$OUTPUT_DIR/mariadb/custom.cnf" "$MARIADB_CONTAINER:$mysql_conf_path/zz-optimize.cnf"
docker restart "$MARIADB_CONTAINER"
log "MariaDB 配置已应用并重启容器"
EOF
        fi
    fi

    # Redis
    if [[ -n "$REDIS_CONTAINER" ]]; then
        cat >> "$APPLY_SCRIPT" << EOF

# ═══ Redis: $REDIS_CONTAINER ═══
log "应用 Redis 配置到容器: $REDIS_CONTAINER"

# 备份
backup_from_container "$REDIS_CONTAINER" "/usr/local/etc/redis/redis.conf" "redis.conf" 2>/dev/null || true
backup_from_container "$REDIS_CONTAINER" "/etc/redis/redis.conf" "redis.conf" 2>/dev/null || true

# 尝试通过 CONFIG SET 在线应用（不需要重启）
docker exec "$REDIS_CONTAINER" redis-cli CONFIG SET maxmemory "${REDIS_MAXMEMORY:-256mb}" 2>/dev/null || true
docker exec "$REDIS_CONTAINER" redis-cli CONFIG SET maxmemory-policy "${REDIS_POLICY}" 2>/dev/null || true
docker exec "$REDIS_CONTAINER" redis-cli CONFIG SET maxclients ${REDIS_MAXCLIENTS} 2>/dev/null || true
docker exec "$REDIS_CONTAINER" redis-cli CONFIG SET tcp-keepalive 300 2>/dev/null || true
docker exec "$REDIS_CONTAINER" redis-cli CONFIG SET slowlog-log-slower-than 10000 2>/dev/null || true
docker exec "$REDIS_CONTAINER" redis-cli CONFIG REWRITE 2>/dev/null || true

log "Redis 配置已在线应用"
EOF
    fi

    # 收尾
    cat >> "$APPLY_SCRIPT" << 'FOOTER'

echo ""
log "═══ 所有配置已应用 ═══"
log "备份目录: $BACKUP_DIR"
log "如需回滚，请从备份目录恢复原始配置文件"
FOOTER

    chmod 755 "$APPLY_SCRIPT"
    log "INFO" "已生成配置应用脚本: $APPLY_SCRIPT"
}

###############################################################################
#  H27: 健康检查脚本
###############################################################################
generate_health_check() {
    step_banner "H27" "健康检查脚本"

    cat > /opt/scripts/health-check.sh << 'HEALTHEOF'
#!/usr/bin/env bash
###############################################################################
#  health-check.sh — 系统健康检查 (每5分钟执行)
###############################################################################
set -uo pipefail

LOG="/var/log/health-check.log"
ALERT_MEM=85
ALERT_DISK=85
ALERT_SWAP=50

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
alert() { echo "[$(ts)] ⚠ ALERT: $*" >> "$LOG"; }

# 内存检查
mem_usage=$(free | awk '/Mem:/{printf "%.0f", $3/$2*100}')
if [[ $mem_usage -gt $ALERT_MEM ]]; then
    alert "内存使用率 ${mem_usage}% (阈值 ${ALERT_MEM}%)"
fi

# 磁盘检查
disk_usage=$(df / | awk 'NR==2{gsub(/%/,""); print $5}')
if [[ $disk_usage -gt $ALERT_DISK ]]; then
    alert "磁盘使用率 ${disk_usage}% (阈值 ${ALERT_DISK}%)"
fi

# Swap 检查
swap_total=$(free | awk '/Swap:/{print $2}')
if [[ $swap_total -gt 0 ]]; then
    swap_usage=$(free | awk '/Swap:/{printf "%.0f", $3/$2*100}')
    if [[ $swap_usage -gt $ALERT_SWAP ]]; then
        alert "Swap 使用率 ${swap_usage}% (阈值 ${ALERT_SWAP}%)"
    fi
fi

# 系统负载
cpu_cores=$(nproc)
load_limit=$((cpu_cores * 2))
load_1m=$(awk '{printf "%.0f", $1}' /proc/loadavg)
if [[ $load_1m -gt $load_limit ]]; then
    alert "系统负载 ${load_1m} (阈值 ${load_limit}, ${cpu_cores}核)"
fi

# Docker 容器检查
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        name=$(echo "$container" | awk '{print $NF}')
        status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
        restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "no")

        if [[ "$status" == "exited" || "$status" == "dead" ]]; then
            alert "Docker 容器 $name 状态: $status"
            if [[ "$restart_policy" != "no" ]]; then
                docker restart "$name" 2>/dev/null && log "已自动重启容器: $name" || alert "容器重启失败: $name"
            fi
        fi
    done < <(docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null)
fi

# 保留最近7天日志
if [[ -f "$LOG" ]]; then
    tail -n 10000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null || true
fi
HEALTHEOF

    chmod 755 /opt/scripts/health-check.sh
    log "INFO" "已生成健康检查脚本: /opt/scripts/health-check.sh"
}

###############################################################################
#  H28: 自动清理脚本
###############################################################################
generate_auto_maintenance() {
    step_banner "H28" "自动清理脚本"

    cat > /opt/scripts/auto-maintenance.sh << 'MAINTEOF'
#!/usr/bin/env bash
###############################################################################
#  auto-maintenance.sh — 自动清理维护 (每周日 4:00)
###############################################################################
set -uo pipefail

LOG="/var/log/auto-maintenance.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

log "=== 开始自动清理 ==="

# APT 缓存清理
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get autoclean -y >/dev/null 2>&1 || true
log "APT 缓存已清理"

# journalctl 日志 vacuum
journalctl --vacuum-time=7d >/dev/null 2>&1 || true
log "journalctl 日志已清理 (保留7天)"

# 旧日志文件清理
find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null || true
find /var/log -name "*.old" -mtime +30 -delete 2>/dev/null || true
find /var/log -name "*.[0-9]" -mtime +30 -delete 2>/dev/null || true
log "旧日志文件已清理"

# Docker 垃圾清理
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    docker system prune -f >/dev/null 2>&1 || true
    # 清理悬空镜像
    docker image prune -f >/dev/null 2>&1 || true
    log "Docker 垃圾已清理"
fi

# PHP session 过期文件清理 (24小时以上)
find /var/lib/php/sessions -name "sess_*" -mmin +1440 -delete 2>/dev/null || true
find /tmp -name "sess_*" -mmin +1440 -delete 2>/dev/null || true
log "PHP session 过期文件已清理"

# Nginx 缓存清理 (7天以上)
find /var/cache/nginx -type f -mtime +7 -delete 2>/dev/null || true
log "Nginx 缓存已清理 (7天以上)"

# 临时文件
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
log "临时文件已清理"

log "=== 清理完成 ==="
MAINTEOF

    chmod 755 /opt/scripts/auto-maintenance.sh
    log "INFO" "已生成自动清理脚本: /opt/scripts/auto-maintenance.sh"
}

###############################################################################
#  H29: OOM 防护
###############################################################################
generate_oom_protection() {
    step_banner "H29" "OOM 防护"

    cat > /opt/scripts/oom-protection.sh << 'OOMEOF'
#!/usr/bin/env bash
###############################################################################
#  oom-protection.sh — OOM 防护 (每天 3:00)
###############################################################################
set -uo pipefail

LOG="/var/log/oom-protection.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

log "=== 刷新 OOM 防护 ==="

# 确保关键 Docker 容器设置 restart=unless-stopped
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(echo "$line" | awk '{print $NF}')
        image=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || echo "")
        image_lower="${image,,}"

        # 检查是否是关键服务
        if [[ "$image_lower" =~ nginx|openresty|php|mariadb|mysql|redis|postgres ]]; then
            current_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "no")
            if [[ "$current_policy" == "no" ]]; then
                docker update --restart unless-stopped "$name" 2>/dev/null || true
                log "已设置 $name restart=unless-stopped"
            fi
        fi
    done < <(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null)
fi

# 主机关键进程 OOM Score 调整
adjust_oom() {
    local proc_name=$1 score=$2
    pids=$(pgrep -f "$proc_name" 2>/dev/null || true)
    for pid in $pids; do
        if [[ -f "/proc/$pid/oom_score_adj" ]]; then
            echo "$score" > "/proc/$pid/oom_score_adj" 2>/dev/null || true
        fi
    done
}

# 降低关键进程被 OOM kill 的概率
adjust_oom "nginx" "-500"
adjust_oom "openresty" "-500"
adjust_oom "mariadbd\|mysqld" "-500"
adjust_oom "redis-server" "-300"
adjust_oom "php-fpm" "-300"
adjust_oom "dockerd" "-900"
adjust_oom "containerd" "-900"
adjust_oom "1panel" "-200"

log "OOM 防护刷新完成"

# 保留最近30天日志
if [[ -f "$LOG" ]]; then
    tail -n 5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null || true
fi
OOMEOF

    chmod 755 /opt/scripts/oom-protection.sh
    log "INFO" "已生成 OOM 防护脚本: /opt/scripts/oom-protection.sh"
}

###############################################################################
#  H30: Crontab 设置
###############################################################################
setup_crontab() {
    step_banner "H30" "Crontab 定时任务"

    local cron_file="/etc/cron.d/web-optimize"
    backup_file "$cron_file"

    cat > "$cron_file" << 'EOF'
# === web-optimize.sh 定时任务 ===
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 健康检查 - 每5分钟
*/5 * * * * root /opt/scripts/health-check.sh >/dev/null 2>&1

# 自动清理 - 每周日 4:00
0 4 * * 0 root /opt/scripts/auto-maintenance.sh >/dev/null 2>&1

# OOM 防护 - 每天 3:00
0 3 * * * root /opt/scripts/oom-protection.sh >/dev/null 2>&1
EOF

    chmod 644 "$cron_file"

    if [[ "$DRY_RUN" != "yes" ]]; then
        log "INFO" "Crontab 已配置: 健康检查(5分钟) + 清理(周日4点) + OOM防护(每天3点)"
    else
        log "INFO" "[DRY-RUN] 已生成 Crontab 配置"
    fi

    echo "rm -f '$cron_file' && echo '已移除定时任务'" >> "$ROLLBACK_SCRIPT"
}

###############################################################################
#  验证
###############################################################################
run_verification() {
    echo "" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}\n" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}║                      验  证  结  果                          ║${NC}\n" | tee -a "$LOG_FILE"
    printf "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}\n" | tee -a "$LOG_FILE"

    PASS_COUNT=0; FAIL_COUNT=0; TOTAL_COUNT=0

    # 系统级
    check_result "BBR 拥塞控制" \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo pass || echo fail)"
    check_result "somaxconn=$SYSCTL_SOMAXCONN" \
        "$([[ $(sysctl -n net.core.somaxconn 2>/dev/null) -ge $SYSCTL_SOMAXCONN ]] && echo pass || echo fail)"
    check_result "file-max=$SYSCTL_FILE_MAX" \
        "$([[ $(sysctl -n fs.file-max 2>/dev/null) -ge $SYSCTL_FILE_MAX ]] && echo pass || echo fail)"
    check_result "swappiness=$SWAPPINESS" \
        "$([[ $(sysctl -n vm.swappiness 2>/dev/null) -eq $SWAPPINESS ]] && echo pass || echo fail)"
    check_result "TCP Fast Open 启用" \
        "$([[ $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null) -eq 3 ]] && echo pass || echo fail)"
    check_result "nofile limits 配置" \
        "$([[ -f /etc/security/limits.d/99-web-optimize.conf ]] && echo pass || echo fail)"

    # 配置文件
    check_result "Nginx 配置已生成" \
        "$([[ -f $OUTPUT_DIR/nginx/nginx.conf ]] && echo pass || echo fail)"
    check_result "PHP-FPM 配置已生成" \
        "$([[ -f $OUTPUT_DIR/php/www.conf ]] && echo pass || echo fail)"
    check_result "MariaDB 配置已生成" \
        "$([[ -f $OUTPUT_DIR/mariadb/custom.cnf ]] && echo pass || echo fail)"
    if [[ -n "$REDIS_CONTAINER" ]]; then
        check_result "Redis 配置已生成" \
            "$([[ -f $OUTPUT_DIR/redis/custom.conf ]] && echo pass || echo fail)"
    fi
    check_result "配置应用脚本已生成" \
        "$([[ -f $APPLY_SCRIPT ]] && echo pass || echo fail)"

    # 运维脚本
    check_result "健康检查脚本" \
        "$([[ -f /opt/scripts/health-check.sh && -x /opt/scripts/health-check.sh ]] && echo pass || echo fail)"
    check_result "自动清理脚本" \
        "$([[ -f /opt/scripts/auto-maintenance.sh && -x /opt/scripts/auto-maintenance.sh ]] && echo pass || echo fail)"
    check_result "OOM 防护脚本" \
        "$([[ -f /opt/scripts/oom-protection.sh && -x /opt/scripts/oom-protection.sh ]] && echo pass || echo fail)"
    check_result "Crontab 已配置" \
        "$([[ -f /etc/cron.d/web-optimize ]] && echo pass || echo fail)"

    echo "" | tee -a "$LOG_FILE"
    local rate=0
    [[ $TOTAL_COUNT -gt 0 ]] && rate=$((PASS_COUNT * 100 / TOTAL_COUNT))
    printf "${BOLD}验证结果: ${GREEN}✓ %d 通过${NC} / ${RED}✗ %d 失败${NC} / 共 %d 项 (通过率 %d%%)${NC}\n" \
        "$PASS_COUNT" "$FAIL_COUNT" "$TOTAL_COUNT" "$rate" | tee -a "$LOG_FILE"
}

###############################################################################
#  YAML 诊断报告
###############################################################################
generate_report() {
    local rate=0
    [[ $TOTAL_COUNT -gt 0 ]] && rate=$((PASS_COUNT * 100 / TOTAL_COUNT))

    local total_mem avail_mem cpu_cores
    total_mem=$(get_total_mem_mb)
    avail_mem=$(get_available_mem_mb)
    cpu_cores=$(get_cpu_cores)

    cat > "$DIAG_FILE" << YAMLEOF
---
# web-optimize.sh 诊断报告
generated_at: "$(date -Iseconds)"
hostname: "$(hostname)"
os: "$(. /etc/os-release && echo "$PRETTY_NAME")"
kernel: "$(uname -r)"
cpu_cores: ${cpu_cores}
memory_total_mb: ${total_mem}
memory_available_mb: ${avail_mem}

containers_detected:
  nginx: "${NGINX_CONTAINER:-未检测到}"
  php_fpm: "${PHP_CONTAINER:-未检测到}"
  mariadb: "${MARIADB_CONTAINER:-未检测到}"
  redis: "${REDIS_CONTAINER:-未检测到}"

system_tuning:
  tcp_congestion: "bbr"
  somaxconn: ${SYSCTL_SOMAXCONN}
  file_max: ${SYSCTL_FILE_MAX}
  nofile: ${ULIMIT_NOFILE}
  swappiness: ${SWAPPINESS}

config_output_dir: "${OUTPUT_DIR}"
apply_script: "${APPLY_SCRIPT}"
dry_run: "${DRY_RUN}"

verification:
  total: ${TOTAL_COUNT}
  passed: ${PASS_COUNT}
  failed: ${FAIL_COUNT}
  pass_rate: "${rate}%"

backup:
  directory: "${BACKUP_DIR}"
  rollback_script: "${ROLLBACK_SCRIPT}"
YAMLEOF

    log "INFO" "诊断报告: $DIAG_FILE"
}

###############################################################################
#  交互菜单
###############################################################################
interactive_menu() {
    echo ""
    printf "${BOLD}${CYAN}═══ 当前系统信息 ═══${NC}\n"
    printf "  CPU: %s 核  |  内存: %sMB 总量, %sMB 可用\n" "$(get_cpu_cores)" "$(get_total_mem_mb)" "$(get_available_mem_mb)"
    printf "  磁盘: %s\n" "$(df -h / | awk 'NR==2{print $2" 总量, "$3" 已用, "$5" 使用率"}')"

    local docker_count
    docker_count=$(docker ps -q 2>/dev/null | wc -l)
    printf "  Docker: %s 个容器运行中\n" "$docker_count"

    if [[ $docker_count -gt 0 ]]; then
        docker ps --format '    - {{.Names}} ({{.Image}})' 2>/dev/null
    fi

    echo ""
    printf "  即将执行:\n"
    printf "    1. 系统内核网络调优 (BBR, TCP优化)\n"
    printf "    2. 文件描述符优化\n"
    printf "    3. 内存策略优化\n"
    printf "    4. 禁用不必要服务\n"
    printf "    5. 检测 Docker 容器\n"
    printf "    6. 生成 Nginx/PHP/MariaDB/Redis 优化配置\n"
    printf "    7. 生成健康检查/清理/OOM防护脚本\n"
    echo ""

    printf "  配置将生成到 ${YELLOW}$OUTPUT_DIR${NC}，不直接修改容器内部文件\n"
    printf "  同时生成 ${YELLOW}apply-docker-configs.sh${NC} 供审查后一键应用\n"
    echo ""

    printf "  是否自动应用 Docker 配置? [y/${YELLOW}N${NC}]: "
    read -r auto_apply
    case "$auto_apply" in
        [yY]*) export AUTO_APPLY="yes" ;;
        *) export AUTO_APPLY="no" ;;
    esac

    printf "  按 ${YELLOW}Enter${NC} 开始执行，${YELLOW}Ctrl+C${NC} 取消..."
    read -r
}

###############################################################################
#  主流程
###############################################################################
main() {
    check_root
    check_os

    for arg in "$@"; do
        case "$arg" in
            --auto) AUTO_MODE="yes" ;;
            --dry-run) DRY_RUN="yes" ;;
            --help|-h)
                echo "用法:"
                echo "  sudo bash $0            # 交互模式"
                echo "  sudo bash $0 --auto     # 自动全量"
                echo "  sudo bash $0 --dry-run  # 仅生成配置不应用"
                exit 0
                ;;
        esac
    done

    init_dirs

    printf "${BOLD}${GREEN}"
    printf "╔═══════════════════════════════════════════════════════════════╗\n"
    printf "║         Web 服务器性能优化脚本 web-optimize.sh              ║\n"
    printf "╚═══════════════════════════════════════════════════════════════╝\n"
    printf "${NC}\n"

    if [[ "$AUTO_MODE" != "yes" && "$DRY_RUN" != "yes" ]]; then
        interactive_menu
    else
        if [[ "$DRY_RUN" == "yes" ]]; then
            log "INFO" "DRY-RUN 模式: 仅生成配置，不修改系统"
        else
            log "INFO" "自动模式启动"
        fi
    fi

    # A: 系统级优化
    tune_kernel_network
    tune_file_descriptors
    tune_memory
    disable_unnecessary_services

    # B: Docker 容器检测
    detect_containers

    # C-F: 生成服务配置（无论是否检测到容器都生成模板）
    generate_nginx_config
    generate_php_config
    generate_mariadb_config
    generate_redis_config

    # G: 生成应用脚本
    generate_apply_script

    # H: 自动化运维
    generate_health_check
    generate_auto_maintenance
    generate_oom_protection
    setup_crontab

    # 完成回滚脚本
    echo 'echo "=== 回滚完成 ==="' >> "$ROLLBACK_SCRIPT"
    chmod 700 "$ROLLBACK_SCRIPT"

    # 如果交互模式选了自动应用，且不是 dry-run
    if [[ "${AUTO_APPLY:-no}" == "yes" && "$DRY_RUN" != "yes" ]]; then
        echo "" | tee -a "$LOG_FILE"
        log "INFO" "正在自动应用 Docker 配置..."
        bash "$APPLY_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    fi

    # 首次执行 OOM 防护
    if [[ "$DRY_RUN" != "yes" ]]; then
        bash /opt/scripts/oom-protection.sh 2>/dev/null || true
    fi

    # 验证
    run_verification

    # 报告
    generate_report

    echo "" | tee -a "$LOG_FILE"
    printf "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}\n" | tee -a "$LOG_FILE"
    printf "${BOLD}${GREEN}║                 性能优化完成                                 ║${NC}\n" | tee -a "$LOG_FILE"
    printf "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}\n" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    log "INFO" "配置输出目录: $OUTPUT_DIR"
    log "INFO" "日志文件: $LOG_FILE"
    log "INFO" "诊断报告: $DIAG_FILE"
    log "INFO" "回滚脚本: $ROLLBACK_SCRIPT"
    echo "" | tee -a "$LOG_FILE"

    if [[ -n "$NGINX_CONTAINER$PHP_CONTAINER$MARIADB_CONTAINER$REDIS_CONTAINER" ]]; then
        printf "${YELLOW}Docker 容器配置应用:${NC}\n" | tee -a "$LOG_FILE"
        printf "  审查配置: ${BOLD}ls -la $OUTPUT_DIR/*/${NC}\n" | tee -a "$LOG_FILE"
        printf "  应用配置: ${BOLD}sudo bash $APPLY_SCRIPT${NC}\n" | tee -a "$LOG_FILE"
    else
        printf "${YELLOW}未检测到 Docker 容器。配置模板已生成到 $OUTPUT_DIR${NC}\n" | tee -a "$LOG_FILE"
        printf "  部署容器后可手动应用配置\n" | tee -a "$LOG_FILE"
    fi
}

main "$@"
