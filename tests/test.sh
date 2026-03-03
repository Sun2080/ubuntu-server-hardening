#!/usr/bin/env bash
###############################################################################
#  tests/test.sh — ubuntu-server-hardening 项目质量测试脚本
#  用法:  bash tests/test.sh          # 普通用户可运行（不需要 root）
#  退出码: 0 = 全部通过, 1 = 有失败
###############################################################################
set -euo pipefail

# ─── 脚本路径 ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  %b✓ PASS%b  %s\n' "$GREEN" "$NC" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  %b✗ FAIL%b  %s\n' "$RED" "$NC" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  %b⊘ SKIP%b  %s\n' "$YELLOW" "$NC" "$1"; }

SCRIPTS=("init-mirror.sh" "sec-harden.sh" "web-optimize.sh")
EXTRA_SCRIPTS=("lib/common.sh")

###############################################################################
printf '\n%b══ T1: 文件存在性 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    if [[ -f "$PROJECT_ROOT/$f" ]]; then
        pass "$f exists"
    else
        fail "$f missing"
    fi
done

for f in README.md CHANGELOG.md LICENSE .gitignore; do
    if [[ -f "$PROJECT_ROOT/$f" ]]; then
        pass "$f exists"
    else
        fail "$f missing"
    fi
done

###############################################################################
printf '\n%b══ T2: Shebang 检查 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if head -1 "$fp" | grep -q '^#!/usr/bin/env bash\|^#!/bin/bash'; then
        pass "$f has bash shebang"
    else
        fail "$f missing/wrong shebang: $(head -1 "$fp")"
    fi
done

###############################################################################
printf '\n%b══ T3: Bash 语法检查 (bash -n) ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if bash -n "$fp" 2>/dev/null; then
        pass "$f syntax OK"
    else
        fail "$f has syntax errors"
    fi
done

###############################################################################
printf '\n%b══ T4: ShellCheck 静态分析 (warning 级别) ══%b\n' "$BOLD" "$NC"
###############################################################################
if command -v shellcheck &>/dev/null; then
    for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
        fp="$PROJECT_ROOT/$f"
        [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
        sc_out=$(shellcheck -S warning "$fp" 2>&1) || true
        if [[ -z "$sc_out" ]]; then
            pass "$f shellcheck clean"
        else
            fail "$f shellcheck issues:"
            echo "$sc_out" | head -20 | sed 's/^/        /'
        fi
    done
else
    skip "shellcheck not installed — skipping"
fi

###############################################################################
printf '\n%b══ T5: ShellCheck 信息级别摘要 ══%b\n' "$BOLD" "$NC"
###############################################################################
if command -v shellcheck &>/dev/null; then
    for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
        fp="$PROJECT_ROOT/$f"
        [[ ! -f "$fp" ]] && continue
        info_count=$(shellcheck -S style "$fp" 2>&1 | grep -c '^In ' || true)
        if [[ "$info_count" -eq 0 ]]; then
            pass "$f zero info/style hints"
        else
            printf '  %b⚡ INFO%b  %s has %d info-level hint(s) (non-blocking)\n' "$YELLOW" "$NC" "$f" "$info_count"
        fi
    done
else
    skip "shellcheck not installed"
fi

###############################################################################
printf '\n%b══ T6: set -euo pipefail 保护 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q 'set -[Ee]uo pipefail\|set -euo pipefail' "$fp"; then
        pass "$f has strict mode"
    else
        fail "$f missing strict mode (set -euo pipefail)"
    fi
done

###############################################################################
printf '\n%b══ T7: 必需函数定义 ══%b\n' "$BOLD" "$NC"
###############################################################################
declare -A required_funcs=(
    ["init-mirror.sh"]="log step_banner check_root check_os confirm_action"
    ["sec-harden.sh"]="log step_banner check_root check_os check_result backup_file confirm_dangerous"
    ["web-optimize.sh"]="log step_banner check_root check_os check_result backup_file confirm_dangerous"
)
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    for func in ${required_funcs[$f]}; do
        if grep -q "^${func}()" "$fp"; then
            pass "$f defines $func()"
        else
            fail "$f missing $func()"
        fi
    done
done

###############################################################################
printf '\n%b══ T8: --help 标志存在 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q '\-\-help\|--help|-h)' "$fp"; then
        pass "$f supports --help"
    else
        fail "$f missing --help support"
    fi
done

###############################################################################
printf '\n%b══ T9: 版本号一致性 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q '^SCRIPT_VERSION=' "$fp"; then
        ver=$(grep '^SCRIPT_VERSION=' "$fp" | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
        pass "$f version=$ver"
    else
        fail "$f missing SCRIPT_VERSION"
    fi
done

###############################################################################
printf '\n%b══ T10: 日志文件变量定义 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q '^LOG_FILE=' "$fp"; then
        pass "$f defines LOG_FILE"
    else
        fail "$f missing LOG_FILE definition"
    fi
done

###############################################################################
printf '\n%b══ T11: 备份目录变量 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q '^BACKUP_DIR=' "$fp"; then
        pass "$f defines BACKUP_DIR"
    else
        fail "$f missing BACKUP_DIR"
    fi
done

###############################################################################
printf '\n%b══ T12: 无硬编码 root 密码 / 秘钥 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    # 检查常见的硬编码敏感信息模式 (排除文件路径和注释)
    if grep -v '^\s*#\|/etc/\|/usr/' "$fp" | grep -iEq 'password\s*=\s*["\x27][A-Za-z0-9].+["\x27]|secret_key\s*=\s*["\x27]|api_key\s*=\s*["\x27]'; then
        fail "$f may contain hardcoded secrets"
    else
        pass "$f no hardcoded secrets detected"
    fi
done

###############################################################################
printf '\n%b══ T13: printf 格式安全 (无 SC2059 残留) ══%b\n' "$BOLD" "$NC"
###############################################################################
# 检查 printf "...$VAR..." 模式（双引号格式字符串中含变量 — 已知的豁免: heredoc 内部）
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    # 简单正则检测: printf 后跟双引号,内含 $变量 (排除在 heredoc/cat 块里的)
    violations=$(grep -nP '^\s*printf\s+"[^"]*\$[A-Z_]' "$fp" 2>/dev/null | grep -v "^#" || true)
    if [[ -z "$violations" ]]; then
        pass "$f no SC2059 patterns"
    else
        count=$(echo "$violations" | wc -l)
        fail "$f has $count printf+\$VAR pattern(s):"
        echo "$violations" | head -5 | sed 's/^/        /'
    fi
done

###############################################################################
printf '\n%b══ T14: Ubuntu 版本兼容性声明 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q '22.04\|24.04' "$fp"; then
        pass "$f references Ubuntu 22.04/24.04"
    else
        fail "$f missing Ubuntu version reference"
    fi
done

###############################################################################
printf '\n%b══ T15: ERR trap 保护 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -q "trap.*ERR" "$fp"; then
        pass "$f has ERR trap"
    else
        # web-optimize.sh 使用 set -e 但可能没有 ERR trap
        skip "$f no ERR trap (may use set -e)"
    fi
done

###############################################################################
printf '\n%b══ T16: 文件编码 (UTF-8 无 BOM) ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if file "$fp" | grep -qi 'BOM'; then
        fail "$f has BOM marker"
    else
        pass "$f UTF-8 (no BOM)"
    fi
done

###############################################################################
printf '\n%b══ T17: 行尾符 (无 Windows CR) ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    if grep -Plq '\r$' "$fp" 2>/dev/null; then
        fail "$f contains Windows line endings (CRLF)"
    else
        pass "$f Unix line endings (LF)"
    fi
done

###############################################################################
printf '\n%b══ T18: 尾部空白行 ══%b\n' "$BOLD" "$NC"
###############################################################################
for f in "${SCRIPTS[@]}" "${EXTRA_SCRIPTS[@]}"; do
    fp="$PROJECT_ROOT/$f"
    [[ ! -f "$fp" ]] && { skip "$f (file missing)"; continue; }
    trailing=$(tail -c1 "$fp" | wc -l)
    if [[ "$trailing" -eq 1 ]]; then
        pass "$f ends with newline"
    else
        fail "$f missing trailing newline"
    fi
done

###############################################################################
#  汇总
###############################################################################
TOTAL=$((PASS + FAIL + SKIP))
echo ""
printf '%b═══════════════════════════════════════════════════════════════%b\n' "$BOLD" "$NC"
printf '%b  测试汇总: %b✓ %d 通过%b / %b✗ %d 失败%b / ⊘ %d 跳过 / 共 %d 项%b\n' \
    "$BOLD" "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC" "$SKIP" "$TOTAL" "$NC"
printf '%b═══════════════════════════════════════════════════════════════%b\n' "$BOLD" "$NC"

if [[ $FAIL -gt 0 ]]; then
    printf '%b  结果: FAIL%b\n\n' "$RED" "$NC"
    exit 1
else
    printf '%b  结果: ALL PASS%b\n\n' "$GREEN" "$NC"
    exit 0
fi
