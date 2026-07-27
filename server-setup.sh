#!/usr/bin/env bash
# =============================================================================
#  server-setup.sh — Linux Server Auto-Configuration Script
#  Version : 1.2.0
#  Author  : MNSH
#  Purpose : راه‌اندازی خودکار سرور لینوکس برای محیط‌های VPN/Proxy
#
#  Phases:
#    0 — Environment check & prerequisites
#    1 — System resource detection (RAM, CPU)
#    2 — XanMod kernel installation (official)
#    3 — Smart sysctl tuning
#    4 — MTU = 1360 configuration
#    5 — iptables / ip6tables TCPMSS
#    6 — Final summary
#
#  Log : /var/log/server-setup.log
# =============================================================================

set -euo pipefail

# ─── ANSI Colors & Styles ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Global Variables ─────────────────────────────────────────────────────────
LOG_FILE="/var/log/server-setup.log"
SCRIPT_VERSION="1.2.0"
SCRIPT_START=$(date '+%Y-%m-%d %H:%M:%S')
MTU_TARGET=1360
MSS_TARGET=1360
SYSCTL_FILE="/etc/sysctl.d/99-server-tuning.conf"
TERM_WIDTH=$(tput cols 2>/dev/null || echo 70)
[[ $TERM_WIDTH -lt 50 ]] && TERM_WIDTH=70

# Phase status trackers
PHASE_ENV="pending"
PHASE_RESOURCES="pending"
PHASE_XANMOD="pending"
PHASE_SYSCTL="pending"
PHASE_MTU="pending"
PHASE_IPTABLES="pending"

# Resource vars (populated later)
RAM_MB=0
CPU_CORES=1
HAS_IPV4=false
HAS_IPV6=false
XANMOD_SKIP_ARCH=false
XANMOD_PKG=""
XANMOD_INSTALLED=false

# Spinner PID tracker
_SPINNER_PID=0

# ─── Progress Tracking ────────────────────────────────────────────────────────
TOTAL_PHASES=6
CURRENT_PHASE=0

# =============================================================================
# UI PRIMITIVES
# =============================================================================

# Print a centered text in a given color
_center() {
    local text="$1" color="${2:-$RESET}" width="${3:-$TERM_WIDTH}"
    local len=${#text}
    local pad=$(( (width - len) / 2 ))
    printf "${color}%${pad}s%s%${pad}s${RESET}\n" "" "$text" ""
}

# Horizontal rule
_hr() {
    local char="${1:-─}" color="${2:-$CYAN}"
    local line
    line=$(printf "%${TERM_WIDTH}s" | tr ' ' "$char")
    echo -e "${color}${line}${RESET}"
}

# ─── Spinner ──────────────────────────────────────────────────────────────────
_spinner_start() {
    local msg="${1:-در حال پردازش...}"
    # Only use spinner if we are in an interactive-like terminal
    if [[ ! -t 1 ]]; then
        echo -e "  ${DIM}${msg}${RESET}" | tee -a "$LOG_FILE"
        return 0
    fi
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        tput civis 2>/dev/null || true   # hide cursor
        while true; do
            printf "\r  ${CYAN}${frames[$i]}${RESET}  ${DIM}${msg}${RESET}   " >&2
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}

_spinner_stop() {
    local status="${1:-ok}"   # ok | warn | fail
    if [[ $_SPINNER_PID -ne 0 ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=0
        tput cnorm 2>/dev/null || true  # restore cursor
    fi
    printf "\r%${TERM_WIDTH}s\r" ""   # clear spinner line
}

# ─── Progress Bar ─────────────────────────────────────────────────────────────
_progress_bar() {
    local current="$1" total="$2" label="${3:-}"
    local bar_width=$(( TERM_WIDTH - 20 ))
    [[ $bar_width -lt 20 ]] && bar_width=20
    local filled=$(( current * bar_width / total ))
    local empty=$(( bar_width - filled ))
    local bar_filled
    local bar_empty
    bar_filled=$(printf "%${filled}s" | tr ' ' '█')
    bar_empty=$(printf "%${empty}s"   | tr ' ' '░')
    local pct=$(( current * 100 / total ))
    printf "\r  ${CYAN}[${bar_filled}${DIM}${bar_empty}${RESET}${CYAN}]${RESET} ${BOLD}%3d%%${RESET}  ${DIM}%s${RESET}   " \
        "$pct" "$label"
}

_progress_done() {
    printf "\n"
}

# ─── Log Functions ────────────────────────────────────────────────────────────
_log_raw() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${ts} $*" | tee -a "$LOG_FILE"
}

log_info()  { _log_raw "  ${BLUE}ℹ${RESET}  $*"; }
log_ok()    { _log_raw "  ${GREEN}✔${RESET}  $*"; }
log_warn()  { _log_raw "  ${YELLOW}⚠${RESET}  $*"; }
log_error() { _log_raw "  ${RED}✖${RESET}  $*"; }

log_sep() {
    local char="${1:-─}"
    _hr "$char" "$CYAN"
}

log_phase() {
    local num="$1" name="$2"
    CURRENT_PHASE=$num
    echo ""
    _hr "─" "$CYAN"
    echo -e "  ${BOLD}${CYAN}◈  فاز ${num}${RESET}${BOLD}  —  ${name}${RESET}"
    _hr "─" "$CYAN"
    echo ""
    # Render overall progress bar
    _progress_bar "$num" "$TOTAL_PHASES" "$name"
    _progress_done
    echo ""
}

# ─── Exit Trap ────────────────────────────────────────────────────────────────
_on_exit() {
    local code=$?
    _spinner_stop
    if [[ $code -ne 0 ]]; then
        echo ""
        _hr "═" "$RED"
        log_error "اسکریپت با کد خطا ${BOLD}$code${RESET} خاتمه یافت."
        log_error "جزئیات: ${BOLD}cat $LOG_FILE${RESET}"
        _hr "═" "$RED"
    fi
}
trap '_on_exit' EXIT

# ─── Safe Command Runner ──────────────────────────────────────────────────────
run_cmd() {
    local desc="$1"; shift
    _spinner_start "$desc"
    local rc=0
    "$@" >> "$LOG_FILE" 2>&1 || rc=$?
    _spinner_stop
    if [[ $rc -eq 0 ]]; then
        log_ok "$desc"
        return 0
    else
        log_error "$desc ${DIM}(کد: $rc)${RESET}"
        return $rc
    fi
}

run_cmd_soft() {
    local desc="$1"; shift
    _spinner_start "$desc"
    local rc=0
    "$@" >> "$LOG_FILE" 2>&1 || rc=$?
    _spinner_stop
    if [[ $rc -eq 0 ]]; then
        log_ok "$desc"
    else
        log_warn "$desc ${DIM}(کد: $rc — ادامه می‌دهیم)${RESET}"
    fi
    return 0
}

# ─── CPU Level Detection ──────────────────────────────────────────────────────
detect_cpu_level() {
    local flags
    flags=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null || echo "")
    local level="x64v1"
    if echo "$flags" | grep -q "sse4_2" && echo "$flags" | grep -q "popcnt"; then
        level="x64v2"
    fi
    if echo "$flags" | grep -qE "(^| )avx( |$)" && echo "$flags" | grep -q "avx2"; then
        level="x64v3"
    fi
    if echo "$flags" | grep -q "avx512f"; then
        level="x64v4"
    fi
    echo "$level"
}

# =============================================================================
# PHASE 0 — Environment Check
# =============================================================================
phase_env() {
    log_phase "0" "بررسی محیط و پیش‌نیازها"

    log_info "server-setup.sh v${SCRIPT_VERSION} — شروع: ${SCRIPT_START}"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        log_error "این اسکریپت باید با ${BOLD}root${RESET} اجرا شود."
        log_error "دستور: ${BOLD}sudo bash $0${RESET}"
        exit 1
    fi
    log_ok "دسترسی root تأیید شد"

    # Distro check
    if [[ ! -f /etc/os-release ]]; then
        log_error "فایل /etc/os-release پیدا نشد. توزیع ناشناخته."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    local distro_id="${ID:-unknown}"
    local distro_like="${ID_LIKE:-}"
    local distro_version="${VERSION_CODENAME:-${VERSION_ID:-unknown}}"
    log_info "توزیع: ${BOLD}$distro_id $distro_version${RESET}"

    local is_debian_based=false
    if [[ "$distro_id" == "debian" || "$distro_id" == "ubuntu" ]]; then
        is_debian_based=true
    elif echo "$distro_like" | grep -qiE "debian|ubuntu"; then
        is_debian_based=true
    fi
    if [[ "$is_debian_based" != "true" ]]; then
        log_error "فقط Debian/Ubuntu پشتیبانی می‌شود (شناسایی‌شده: $distro_id)."
        exit 1
    fi
    log_ok "توزیع Debian-based: ${BOLD}$distro_id $distro_version${RESET}"

    # Architecture
    local arch
    arch=$(uname -m)
    log_info "معماری: ${BOLD}$arch${RESET}"
    if [[ "$arch" != "x86_64" ]]; then
        log_warn "معماری $arch — نصب XanMod رد می‌شود"
        XANMOD_SKIP_ARCH=true
    else
        XANMOD_SKIP_ARCH=false
        log_ok "معماری ${BOLD}x86_64${RESET} تأیید شد"
    fi

    # IPv4/IPv6 detection
    log_info "تشخیص آدرس‌های شبکه..."
    local ipv4_addr
    ipv4_addr=$(ip -4 addr show 2>/dev/null \
        | awk '/inet / && !/127\./{print $2}' \
        | head -1 || true)
    if [[ -n "$ipv4_addr" ]]; then
        HAS_IPV4=true
        log_ok "IPv4: ${BOLD}$ipv4_addr${RESET}"
    else
        log_warn "IPv4 شناسایی نشد"
    fi
    if ip -6 addr show 2>/dev/null | grep -q "inet6 " && \
       ip -6 addr show 2>/dev/null | grep "inet6 " | grep -qv "::1"; then
        HAS_IPV6=true
        local ipv6_addr
        ipv6_addr=$(ip -6 addr show | grep "inet6 " | grep -v "::1" | awk '{print $2}' | head -1)
        log_ok "IPv6: ${BOLD}$ipv6_addr${RESET}"
    else
        log_warn "IPv6 شناسایی نشد"
    fi

    # Internet connectivity
    log_info "بررسی اتصال اینترنت..."
    local internet_ok=false
    if curl -fsSL --max-time 15 --retry 2 https://dl.xanmod.org/ -o /dev/null 2>/dev/null; then
        internet_ok=true
        log_ok "اتصال به ${BOLD}dl.xanmod.org${RESET} برقرار است"
    else
        log_warn "dl.xanmod.org در دسترس نیست — endpoint جایگزین..."
        if curl -fsSL --max-time 15 https://1.1.1.1 -o /dev/null 2>/dev/null; then
            internet_ok=true
            log_warn "اینترنت برقرار — XanMod ممکن است کند باشد"
        else
            if [[ "$HAS_IPV6" == "true" ]]; then
                if curl -fsSL --max-time 15 -6 https://ipv6.google.com -o /dev/null 2>/dev/null; then
                    internet_ok=true
                    log_warn "فقط IPv6 به اینترنت دسترسی دارد"
                fi
            fi
        fi
    fi
    if [[ "$internet_ok" == "false" ]]; then
        log_error "اتصال اینترنت برقرار نیست."
        exit 1
    fi

    # Base packages
    log_info "به‌روزرسانی apt و نصب ابزارهای پایه..."
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1
    local apt_rc=$?
    set -e
    if [[ $apt_rc -ne 0 ]]; then
        log_warn "apt-get update کد $apt_rc — ادامه می‌دهیم"
    else
        log_ok "apt-get update"
    fi
    DEBIAN_FRONTEND=noninteractive run_cmd_soft \
        "نصب curl, gnupg, ca-certificates, apt-transport-https" \
        apt-get install -y -qq curl gnupg ca-certificates apt-transport-https

    PHASE_ENV="done"
    log_ok "${BOLD}فاز 0 کامل شد${RESET}"
}

# =============================================================================
# PHASE 1 — Resource Detection
# =============================================================================
phase_resources() {
    log_phase "1" "تشخیص منابع سیستم"

    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_MB=$(( ram_kb / 1024 ))
    log_info "RAM: ${BOLD}${RAM_MB} MB${RESET} (${ram_kb} KB)"

    local cores_detected
    cores_detected=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo || echo "1")
    CPU_CORES=$cores_detected
    log_info "CPU هسته‌ها: ${BOLD}${CPU_CORES}${RESET}"

    local cpu_model
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs 2>/dev/null || echo "نامشخص")
    log_info "مدل CPU: ${BOLD}${cpu_model}${RESET}"

    local kernel_cur
    kernel_cur=$(uname -r)
    log_info "کرنل فعلی: ${BOLD}${kernel_cur}${RESET}"

    PHASE_RESOURCES="done"
    log_ok "${BOLD}فاز 1 کامل — RAM: ${RAM_MB}MB | CPU: ${CPU_CORES} هسته${RESET}"
}

# =============================================================================
# PHASE 2 — XanMod Kernel
# =============================================================================
phase_xanmod() {
    log_phase "2" "نصب کرنل XanMod"

    if [[ "$XANMOD_SKIP_ARCH" == "true" ]]; then
        log_warn "معماری غیر x86_64 — نصب XanMod رد شد"
        PHASE_XANMOD="skipped"
        return 0
    fi

    set +e
    local already_installed
    already_installed=$(dpkg -l 2>/dev/null | grep "linux-xanmod" | awk '{print $2}' | head -1)
    set -e
    if [[ -n "$already_installed" ]]; then
        log_warn "XanMod قبلاً نصب شده: ${BOLD}$already_installed${RESET}"
        XANMOD_PKG="$already_installed"
        XANMOD_INSTALLED=true
        PHASE_XANMOD="already_installed"
        return 0
    fi

    local cpu_level
    cpu_level=$(detect_cpu_level)
    log_info "سطح CPU: ${BOLD}$cpu_level${RESET}"

    case "$cpu_level" in
        x64v4) XANMOD_PKG="linux-xanmod-x64v4" ;;
        x64v3) XANMOD_PKG="linux-xanmod-x64v3" ;;
        x64v2) XANMOD_PKG="linux-xanmod-x64v2" ;;
        *)     XANMOD_PKG="linux-xanmod-x64v1" ;;
    esac
    log_info "بسته انتخابی: ${BOLD}$XANMOD_PKG${RESET}"

    # GPG Key
    log_info "دریافت GPG key رسمی XanMod..."
    mkdir -p /etc/apt/keyrings
    local gpg_tmp
    gpg_tmp=$(mktemp /tmp/xanmod-gpg.XXXXXX)

    _spinner_start "دریافت GPG key از dl.xanmod.org"
    set +e
    curl -fsSL --max-time 30 --retry 2 \
        https://dl.xanmod.org/archive.key -o "$gpg_tmp" 2>>"$LOG_FILE"
    local curl_rc=$?
    set -e
    _spinner_stop

    if [[ $curl_rc -ne 0 ]] || [[ ! -s "$gpg_tmp" ]]; then
        rm -f "$gpg_tmp"
        log_error "دریافت GPG key ناموفق (کد: $curl_rc)"
        PHASE_XANMOD="failed"
        return 1
    fi

    set +e
    gpg --dearmor < "$gpg_tmp" \
        > /etc/apt/keyrings/xanmod-archive-keyring.gpg 2>>"$LOG_FILE"
    local gpg_rc=$?
    set -e
    rm -f "$gpg_tmp"

    if [[ $gpg_rc -ne 0 ]]; then
        log_error "پردازش GPG key ناموفق (کد: $gpg_rc)"
        PHASE_XANMOD="failed"
        return 1
    fi
    log_ok "GPG key XanMod نصب شد"

    # Repository
    local distro_codename
    distro_codename=$(lsb_release -sc 2>/dev/null \
        || grep VERSION_CODENAME /etc/os-release | cut -d= -f2 \
        || echo "noble")
    log_info "Codename: ${BOLD}$distro_codename${RESET}"

    echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] \
http://deb.xanmod.org ${distro_codename} main" \
        > /etc/apt/sources.list.d/xanmod-release.list
    log_ok "Repository XanMod اضافه شد"

    # apt update
    _spinner_start "به‌روزرسانی apt (XanMod repository)"
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1
    local upd_rc=$?
    set -e
    _spinner_stop
    if [[ $upd_rc -ne 0 ]]; then
        log_warn "apt-get update کد $upd_rc — ادامه..."
    else
        log_ok "apt-get update"
    fi

    # Install kernel
    _spinner_start "نصب $XANMOD_PKG (ممکن است چند دقیقه طول بکشد...)"
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$XANMOD_PKG" >> "$LOG_FILE" 2>&1
    local inst_rc=$?
    set -e
    _spinner_stop

    if [[ $inst_rc -eq 0 ]]; then
        log_ok "بسته ${BOLD}$XANMOD_PKG${RESET} نصب شد"
        XANMOD_INSTALLED=true
        PHASE_XANMOD="done"
    else
        log_warn "$XANMOD_PKG نصب نشد (کد: $inst_rc) — تلاش با سطوح پایین‌تر..."
        local fallback_levels=("x64v3" "x64v2" "x64v1")
        local fallback_installed=false
        for lvl in "${fallback_levels[@]}"; do
            local fallback_pkg="linux-xanmod-${lvl}"
            [[ "$fallback_pkg" == "$XANMOD_PKG" ]] && continue
            log_info "تلاش با: ${BOLD}$fallback_pkg${RESET}"
            _spinner_start "نصب $fallback_pkg"
            set +e
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$fallback_pkg" \
                >> "$LOG_FILE" 2>&1
            local fb_rc=$?
            set -e
            _spinner_stop
            if [[ $fb_rc -eq 0 ]]; then
                log_ok "بسته ${BOLD}$fallback_pkg${RESET} نصب شد (جایگزین)"
                XANMOD_PKG="$fallback_pkg"
                XANMOD_INSTALLED=true
                fallback_installed=true
                PHASE_XANMOD="done"
                break
            fi
        done
        if [[ "$fallback_installed" != "true" ]]; then
            log_error "نصب XanMod کاملاً ناموفق — ادامه می‌دهیم"
            PHASE_XANMOD="failed"
            return 0
        fi
    fi

    log_ok "${BOLD}فاز 2 کامل — $XANMOD_PKG${RESET}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  REBOOT لازم است تا XanMod + BBRv3 فعال شود${RESET}"
}

# =============================================================================
# PHASE 3 — Smart sysctl Tuning
# =============================================================================
phase_sysctl() {
    log_phase "3" "تنظیمات sysctl هوشمند"

    # ── Buffer sizing — base 64MB @ 2GB RAM ──────────────────────────────────
    local buf_base=67108864
    local buf_max_bytes
    buf_max_bytes=$(( RAM_MB * buf_base / 2048 ))
    local buf_min=33554432
    local buf_cap=268435456
    (( buf_max_bytes < buf_min )) && buf_max_bytes=$buf_min
    (( buf_max_bytes > buf_cap  )) && buf_max_bytes=$buf_cap
    log_info "rmem_max / wmem_max: ${BOLD}$(( buf_max_bytes / 1024 / 1024 )) MB${RESET}"

    local tcp_rmem="4096 87380 ${buf_max_bytes}"
    local tcp_wmem="4096 65536 ${buf_max_bytes}"

    # ── tcp_mem ────────────────────────────────────────────────────────────────
    local tcp_mem_low tcp_mem_pressure tcp_mem_high
    tcp_mem_low=$(( RAM_MB * 65536 / 2048 ))
    tcp_mem_pressure=$(( RAM_MB * 1048576 / 2048 ))
    tcp_mem_high=$(( RAM_MB * 1572864 / 2048 ))
    (( tcp_mem_low      < 16384   )) && tcp_mem_low=16384
    (( tcp_mem_pressure < 262144  )) && tcp_mem_pressure=262144
    (( tcp_mem_high     < 524288  )) && tcp_mem_high=524288
    if (( tcp_mem_high > 3145728 )); then
        tcp_mem_high=3145728
        tcp_mem_pressure=$(( tcp_mem_high * 2 / 3 ))
        tcp_mem_low=$(( tcp_mem_high / 3 ))
    fi
    log_info "tcp_mem: ${BOLD}$tcp_mem_low $tcp_mem_pressure $tcp_mem_high${RESET}"

    # ── Queues ─────────────────────────────────────────────────────────────────
    local somaxconn
    somaxconn=$(( CPU_CORES * 16384 ))
    (( somaxconn < 16384 )) && somaxconn=16384
    (( somaxconn > 65536 )) && somaxconn=65536
    local syn_backlog=$(( somaxconn / 2 ))
    log_info "somaxconn: ${BOLD}$somaxconn${RESET} | syn_backlog: ${BOLD}$syn_backlog${RESET}"

    # ── tw_buckets ─────────────────────────────────────────────────────────────
    local tw_buckets
    tw_buckets=$(( RAM_MB * 1440000 / 2048 ))
    (( tw_buckets < 180000  )) && tw_buckets=180000
    (( tw_buckets > 1440000 )) && tw_buckets=1440000
    log_info "tcp_max_tw_buckets: ${BOLD}$tw_buckets${RESET}"

    # ── conntrack ─────────────────────────────────────────────────────────────
    local conntrack_max
    conntrack_max=$(( RAM_MB * 262144 / 2048 ))
    (( conntrack_max < 32768   )) && conntrack_max=32768
    (( conntrack_max > 2097152 )) && conntrack_max=2097152
    log_info "nf_conntrack_max: ${BOLD}$conntrack_max${RESET}"

    # ── file-max ───────────────────────────────────────────────────────────────
    local file_max
    file_max=$(( RAM_MB * 1048576 / 2048 ))
    (( file_max < 262144  )) && file_max=262144
    (( file_max > 4194304 )) && file_max=4194304
    log_info "fs.file-max: ${BOLD}$file_max${RESET}"

    # ── conntrack module ───────────────────────────────────────────────────────
    local has_conntrack=false
    set +e
    if modprobe nf_conntrack 2>/dev/null; then
        has_conntrack=true
        log_ok "ماژول nf_conntrack لود شد"
    elif [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        has_conntrack=true
        log_ok "ماژول nf_conntrack از قبل لود شده"
    else
        log_warn "nf_conntrack در دسترس نیست — conntrack رد می‌شود"
    fi
    set -e

    # ── Write /etc/sysctl.conf ────────────────────────────────────────────────
    local SYSCTL_MAIN="/etc/sysctl.conf"
    if [[ -f "$SYSCTL_MAIN" ]]; then
        cp "$SYSCTL_MAIN" "${SYSCTL_MAIN}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "پشتیبان sysctl.conf ذخیره شد"
    fi
    log_info "نوشتن ${BOLD}$SYSCTL_MAIN${RESET} ..."

    cat > "$SYSCTL_MAIN" << SYSCTL_EOF
# =============================================================================
# Network Tuning for VPN/Proxy — server-setup.sh v${SCRIPT_VERSION}
# Generated : $(date '+%Y-%m-%d %H:%M:%S')
# RAM: ${RAM_MB} MB | CPU: ${CPU_CORES} core(s)
# =============================================================================

# ── Buffers (scale: RAM=${RAM_MB}MB) ─────────────────────────────────────────
net.core.rmem_max = ${buf_max_bytes}
net.core.wmem_max = ${buf_max_bytes}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_mem = ${tcp_mem_low} ${tcp_mem_pressure} ${tcp_mem_high}
net.ipv4.tcp_notsent_lowat = 131072

# ── Window Scaling & Handshakes ──────────────────────────────────────────────
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# ── Queue Capacity (CPU=${CPU_CORES} cores, RAM=${RAM_MB}MB) ─────────────────
net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}

# ── Port recycling & Timers ───────────────────────────────────────────────────
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0

# ── BBR + FQ ──────────────────────────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_mtu_probing = 1
vm.swappiness = 10

# ── TIME_WAIT & Orphans ───────────────────────────────────────────────────────
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_max_orphans = 65536

# ── Dirty pages latency ───────────────────────────────────────────────────────
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2

# ── NAPI poll ─────────────────────────────────────────────────────────────────
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# ── Filesystem ────────────────────────────────────────────────────────────────
fs.file-max = ${file_max}

SYSCTL_EOF

    if [[ "$has_conntrack" == "true" ]]; then
        cat >> "$SYSCTL_MAIN" << SYSCTL_CONNTRACK
# ── Conntrack ─────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${conntrack_max}
net.netfilter.nf_conntrack_tcp_timeout_established = 600

SYSCTL_CONNTRACK
        log_ok "تنظیمات conntrack اضافه شد: conntrack_max=${BOLD}${conntrack_max}${RESET}"
    fi

    if [[ "$HAS_IPV6" == "true" ]] || [[ -d /proc/sys/net/ipv6 ]]; then
        cat >> "$SYSCTL_MAIN" << SYSCTL_IPV6
# ── IPv6 ──────────────────────────────────────────────────────────────────────
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.route.max_size = 409600
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

SYSCTL_IPV6
        log_ok "تنظیمات IPv6 اضافه شد"
    fi

    log_ok "فایل ${BOLD}$SYSCTL_MAIN${RESET} نوشته شد"

    # Remove old sysctl.d file if exists
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        log_info "فایل قدیمی $SYSCTL_FILE حذف شد"
    fi

    # Apply sysctl
    log_info "اعمال تنظیمات sysctl..."
    set +e
    sysctl --system >> "$LOG_FILE" 2>&1
    local sysctl_sys_rc=$?
    set -e
    if [[ $sysctl_sys_rc -eq 0 ]]; then
        log_ok "تنظیمات sysctl اعمال شد"
    else
        log_warn "sysctl --system کد $sysctl_sys_rc — اعمال مستقیم..."
        set +e
        sysctl -p "$SYSCTL_MAIN" >> "$LOG_FILE" 2>&1
        local sysctl_p_rc=$?
        set -e
        if [[ $sysctl_p_rc -eq 0 ]]; then
            log_ok "اعمال مستقیم $SYSCTL_MAIN موفق"
        else
            log_warn "برخی پارامترها اعمال نشدند (کرنل ممکن است پشتیبانی نکند)"
        fi
    fi

    # BBR check
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "نامشخص")
    if [[ "$current_cc" == "bbr" ]]; then
        log_ok "BBR فعال است"
    else
        log_warn "CC فعلی: ${BOLD}$current_cc${RESET} — BBR بعد از reboot با XanMod فعال می‌شود"
    fi

    # limits.conf
    log_info "تنظیم /etc/security/limits.conf ..."
    local limits_file="/etc/security/limits.conf"
    local limits_marker="# server-setup.sh managed"
    if grep -q "$limits_marker" "$limits_file" 2>/dev/null; then
        sed -i "/$limits_marker/,/# end server-setup.sh/d" "$limits_file" 2>>"$LOG_FILE" || true
        log_info "تنظیمات قبلی limits.conf پاک شد"
    fi
    local nofile_limit
    nofile_limit=$(( file_max * 4 / 5 ))
    (( nofile_limit > 1048576 )) && nofile_limit=1048576

    cat >> "$limits_file" << LIMITS_EOF
${limits_marker}
*    soft nofile ${nofile_limit}
*    hard nofile ${nofile_limit}
root soft nofile ${nofile_limit}
root hard nofile ${nofile_limit}
# end server-setup.sh
LIMITS_EOF
    log_ok "limits.conf — nofile=${BOLD}${nofile_limit}${RESET}"

    # systemd DefaultLimitNOFILE
    local systemd_conf="/etc/systemd/system.conf"
    local systemd_nofile_cur
    systemd_nofile_cur=$(grep "^DefaultLimitNOFILE" "$systemd_conf" 2>/dev/null \
        | cut -d= -f2 || echo "0")
    if [[ "$systemd_nofile_cur" != "$nofile_limit" ]]; then
        sed -i '/^DefaultLimitNOFILE/d' "$systemd_conf" 2>/dev/null || true
        echo "DefaultLimitNOFILE=${nofile_limit}" >> "$systemd_conf"
        log_ok "systemd DefaultLimitNOFILE=${BOLD}${nofile_limit}${RESET}"
        run_cmd_soft "reload systemd" systemctl daemon-reexec
    else
        log_info "systemd DefaultLimitNOFILE از قبل صحیح: $systemd_nofile_cur"
    fi

    PHASE_SYSCTL="done"
    log_ok "${BOLD}فاز 3 کامل شد${RESET}"
}

# =============================================================================
# PHASE 4 — MTU
# =============================================================================
phase_mtu() {
    log_phase "4" "تنظیم MTU روی $MTU_TARGET"

    local interfaces
    interfaces=$(ip -o link show up 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | awk '{print $1}' \
        | grep -vE '^(lo|docker[0-9]*|br-[0-9a-f]+|veth[0-9a-f]+|virbr[0-9]*)$' \
        || true)

    if [[ -z "$interfaces" ]]; then
        log_warn "هیچ اینترفیسی برای MTU پیدا نشد"
        PHASE_MTU="skipped"
        return 0
    fi
    log_info "اینترفیس‌ها: ${BOLD}$(echo "$interfaces" | tr '\n' ' ')${RESET}"

    _persist_mtu "$interfaces"

    local mtu_set_count=0 mtu_failed_count=0
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local current_mtu
        current_mtu=$(ip link show "$iface" 2>/dev/null \
            | grep -o "mtu [0-9]*" | awk '{print $2}' || echo "?")
        log_info "  ${BOLD}$iface${RESET}  MTU: $current_mtu → ${BOLD}$MTU_TARGET${RESET}"
        set +e
        ip link set dev "$iface" mtu "$MTU_TARGET" 2>>"$LOG_FILE"
        local mtu_rc=$?
        set -e
        if [[ $mtu_rc -eq 0 ]]; then
            log_ok "$iface MTU=${BOLD}$MTU_TARGET${RESET}"
            mtu_set_count=$(( mtu_set_count + 1 ))
        else
            log_warn "$iface MTU تنظیم نشد"
            mtu_failed_count=$(( mtu_failed_count + 1 ))
        fi
    done <<< "$interfaces"

    log_info "MTU: ${BOLD}$mtu_set_count${RESET} موفق، ${mtu_failed_count} ناموفق"
    PHASE_MTU="done"
    log_ok "${BOLD}فاز 4 کامل شد${RESET}"
}

_persist_mtu() {
    local interfaces="$1"
    log_info "تعیین روش ماندگاری MTU..."

    # Netplan
    set +e
    local netplan_has_yaml=false
    if command -v netplan &>/dev/null; then
        local np_yaml_count
        np_yaml_count=$(ls /etc/netplan/*.yaml 2>/dev/null | wc -l)
        (( np_yaml_count > 0 )) && netplan_has_yaml=true
    fi
    set -e

    if [[ "$netplan_has_yaml" == "true" ]]; then
        log_info "Netplan شناسایی شد"
        local netplan_modified=false
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            local np_file
            set +e
            np_file=$(grep -rl "$iface" /etc/netplan/*.yaml 2>/dev/null | head -1 || true)
            set -e
            if [[ -n "$np_file" ]]; then
                if grep -q "mtu:" "$np_file" 2>/dev/null; then
                    set +e
                    sed -i "s/mtu:.*$/mtu: $MTU_TARGET/" "$np_file" 2>>"$LOG_FILE"
                    set -e
                    log_ok "MTU در $np_file به‌روز شد"
                else
                    log_warn "$iface در netplan پیکربندی MTU ندارد"
                fi
                netplan_modified=true
            fi
        done <<< "$interfaces"
        [[ "$netplan_modified" == "true" ]] && run_cmd_soft "netplan apply" netplan apply
    fi

    # NetworkManager
    set +e
    local nm_active=false
    if command -v nmcli &>/dev/null; then
        systemctl is-active --quiet NetworkManager 2>/dev/null && nm_active=true
    fi
    set -e

    if [[ "$nm_active" == "true" ]]; then
        log_info "NetworkManager شناسایی شد"
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            local con_name
            set +e
            con_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
                | grep ":${iface}$" | cut -d: -f1 | head -1 || true)
            set -e
            if [[ -n "$con_name" ]]; then
                run_cmd_soft "MTU NetworkManager: $iface" \
                    nmcli con mod "$con_name" 802-3-ethernet.mtu "$MTU_TARGET"
            fi
        done <<< "$interfaces"
    fi

    # systemd unit fallback
    log_info "ایجاد systemd unit برای MTU (fallback)..."
    local unit_file="/etc/systemd/system/set-mtu.service"
    local exec_lines_file
    exec_lines_file=$(mktemp /tmp/exec-lines.XXXXXX)
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        printf 'ExecStart=/sbin/ip link set dev %s mtu %s\n' \
            "$iface" "$MTU_TARGET" >> "$exec_lines_file"
    done <<< "$interfaces"
    local exec_lines
    exec_lines=$(cat "$exec_lines_file")
    rm -f "$exec_lines_file"

    cat > "$unit_file" << UNIT_EOF
[Unit]
Description=Set MTU to ${MTU_TARGET} on network interfaces
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
${exec_lines}

[Install]
WantedBy=multi-user.target
UNIT_EOF

    run_cmd_soft "reload systemd" systemctl daemon-reload
    run_cmd_soft "فعال‌سازی set-mtu.service" systemctl enable --now set-mtu.service
    log_ok "systemd unit MTU ایجاد شد: $unit_file"
}

# =============================================================================
# PHASE 5 — iptables / ip6tables
# =============================================================================
phase_iptables() {
    log_phase "5" "پیکربندی iptables / TCPMSS"

    log_info "نصب iptables و iptables-persistent..."
    set +e
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" \
        | debconf-set-selections 2>/dev/null
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" \
        | debconf-set-selections 2>/dev/null
    set -e

    set +e
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq iptables iptables-persistent >> "$LOG_FILE" 2>&1
    local inst_rc=$?
    set -e

    if [[ $inst_rc -ne 0 ]]; then
        log_warn "iptables-persistent ناموفق — تلاش با iptables تنها..."
        run_cmd_soft "نصب iptables" apt-get install -y -qq iptables
    else
        log_ok "iptables و iptables-persistent نصب شدند"
    fi

    if ! command -v iptables &>/dev/null; then
        log_error "iptables بعد از نصب در PATH پیدا نشد"
        PHASE_IPTABLES="failed"
        return 1
    fi
    log_ok "iptables: $(iptables --version 2>/dev/null | head -1)"

    if [[ "$HAS_IPV4" == "true" ]]; then
        log_info "اعمال IPv4 TCPMSS..."
        _apply_tcpmss_v4
    else
        log_warn "IPv4 شناسایی نشد — قانون IPv4 رد شد"
    fi

    if [[ "$HAS_IPV6" == "true" ]]; then
        if command -v ip6tables &>/dev/null; then
            log_info "اعمال IPv6 TCPMSS..."
            _apply_tcpmss_v6
        else
            log_warn "ip6tables پیدا نشد"
        fi
    else
        log_info "IPv6 فعال نیست — ip6tables رد شد"
    fi

    _save_iptables_rules

    set +e
    if systemctl list-unit-files 2>/dev/null | grep -q "netfilter-persistent"; then
        run_cmd_soft "فعال‌سازی netfilter-persistent" \
            systemctl enable netfilter-persistent
    fi
    set -e

    PHASE_IPTABLES="done"
    log_ok "${BOLD}فاز 5 کامل شد${RESET}"
}

_apply_tcpmss_v4() {
    set +e
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS_TARGET" 2>/dev/null
    local check_rc=$?
    set -e
    if [[ $check_rc -eq 0 ]]; then
        log_warn "قانون TCPMSS IPv4 از قبل موجود"
        return 0
    fi
    set +e
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS_TARGET" 2>>"$LOG_FILE"
    local add_rc=$?
    set -e
    if [[ $add_rc -eq 0 ]]; then
        log_ok "قانون TCPMSS IPv4 اعمال شد (MSS=${BOLD}$MSS_TARGET${RESET})"
    else
        log_error "اعمال TCPMSS IPv4 ناموفق (کد: $add_rc)"
        return 1
    fi
    set +e
    local rule_count
    rule_count=$(iptables -t mangle -L POSTROUTING -n 2>/dev/null \
        | grep -c "TCPMSS" || echo "0")
    set -e
    log_info "قوانین TCPMSS فعال (IPv4): $rule_count"
}

_apply_tcpmss_v6() {
    set +e
    ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS_TARGET" 2>/dev/null
    local check_rc=$?
    set -e
    if [[ $check_rc -eq 0 ]]; then
        log_warn "قانون TCPMSS IPv6 از قبل موجود"
        return 0
    fi
    set +e
    ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$MSS_TARGET" 2>>"$LOG_FILE"
    local add_rc=$?
    set -e
    if [[ $add_rc -eq 0 ]]; then
        log_ok "قانون TCPMSS IPv6 اعمال شد (MSS=${BOLD}$MSS_TARGET${RESET})"
    else
        log_warn "اعمال TCPMSS IPv6 ناموفق (کد: $add_rc)"
    fi
}

_save_iptables_rules() {
    log_info "ذخیره‌سازی قوانین iptables..."
    mkdir -p /etc/iptables
    if command -v iptables-save &>/dev/null; then
        set +e
        iptables-save > /etc/iptables/rules.v4 2>>"$LOG_FILE"
        local sv4_rc=$?
        set -e
        [[ $sv4_rc -eq 0 ]] \
            && log_ok "rules.v4 ذخیره شد" \
            || log_warn "ذخیره rules.v4 ناموفق"
    fi
    if [[ "$HAS_IPV6" == "true" ]] && command -v ip6tables-save &>/dev/null; then
        set +e
        ip6tables-save > /etc/iptables/rules.v6 2>>"$LOG_FILE"
        local sv6_rc=$?
        set -e
        [[ $sv6_rc -eq 0 ]] \
            && log_ok "rules.v6 ذخیره شد" \
            || log_warn "ذخیره rules.v6 ناموفق"
    fi
    if command -v netfilter-persistent &>/dev/null; then
        run_cmd_soft "netfilter-persistent save" netfilter-persistent save
    fi
}

# =============================================================================
# PHASE 6 — Final Summary
# =============================================================================
phase_summary() {
    local divider
    divider=$(printf "%${TERM_WIDTH}s" | tr ' ' '═')

    echo ""
    echo -e "${BOLD}${CYAN}${divider}${RESET}"
    _center "✦  نتیجه اجرای server-setup.sh v${SCRIPT_VERSION}  ✦" "${BOLD}${WHITE}"
    echo -e "${BOLD}${CYAN}${divider}${RESET}"
    echo ""

    # Status table
    _status_row() {
        local srow_name="$1" srow_status="$2"
        case "$srow_status" in
            done)
                echo -e "  ${GREEN}  ✔  ${RESET}${BOLD}${srow_name}${RESET}" | tee -a "$LOG_FILE" ;;
            skipped)
                echo -e "  ${YELLOW}  ⊘  ${RESET}${srow_name} ${DIM}(رد شد)${RESET}" | tee -a "$LOG_FILE" ;;
            already_installed)
                echo -e "  ${CYAN}  ↺  ${RESET}${srow_name} ${DIM}(قبلاً نصب شده)${RESET}" | tee -a "$LOG_FILE" ;;
            failed)
                echo -e "  ${RED}  ✖  ${RESET}${RED}${srow_name} (ناموفق)${RESET}" | tee -a "$LOG_FILE" ;;
            pending)
                echo -e "  ${YELLOW}  ?  ${RESET}${srow_name} ${DIM}(ناتمام)${RESET}" | tee -a "$LOG_FILE" ;;
            *)
                echo -e "  ${YELLOW}  ~  ${RESET}${srow_name} ${DIM}($srow_status)${RESET}" | tee -a "$LOG_FILE" ;;
        esac
    }

    echo -e "  ${BOLD}${CYAN}┌─ وضعیت فازها ───────────────────────────────────${RESET}"
    _status_row "فاز 0 — بررسی محیط"            "$PHASE_ENV"
    _status_row "فاز 1 — تشخیص منابع"            "$PHASE_RESOURCES"
    _status_row "فاز 2 — کرنل XanMod"             "$PHASE_XANMOD"
    _status_row "فاز 3 — تنظیمات sysctl"          "$PHASE_SYSCTL"
    _status_row "فاز 4 — تنظیم MTU ($MTU_TARGET)" "$PHASE_MTU"
    _status_row "فاز 5 — iptables / TCPMSS"        "$PHASE_IPTABLES"
    echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────${RESET}"
    echo ""

    # System info
    echo -e "  ${BOLD}${CYAN}┌─ اطلاعات سیستم ─────────────────────────────────${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  RAM        : ${BOLD}${RAM_MB} MB${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  CPU Cores  : ${BOLD}${CPU_CORES}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  IPv4       : ${BOLD}${HAS_IPV4}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  IPv6       : ${BOLD}${HAS_IPV6}${RESET}" | tee -a "$LOG_FILE"
    [[ -n "$XANMOD_PKG" ]] && \
        echo -e "  ${CYAN}│${RESET}  XanMod    : ${BOLD}${XANMOD_PKG}${RESET}" | tee -a "$LOG_FILE"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "نامشخص")
    echo -e "  ${CYAN}│${RESET}  CC فعلی   : ${BOLD}${current_cc}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────${RESET}" | tee -a "$LOG_FILE"
    echo ""

    # Applied settings
    echo -e "  ${BOLD}${CYAN}┌─ تنظیمات اعمال‌شده ──────────────────────────────${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  MTU        : ${BOLD}${MTU_TARGET}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  MSS        : ${BOLD}${MSS_TARGET}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${CYAN}│${RESET}  sysctl     : ${BOLD}/etc/sysctl.conf${RESET}" | tee -a "$LOG_FILE"
    [[ "$HAS_IPV4" == "true" ]] && \
        echo -e "  ${CYAN}│${RESET}  iptables   : ${BOLD}/etc/iptables/rules.v4${RESET}" | tee -a "$LOG_FILE"
    [[ "$HAS_IPV6" == "true" ]] && \
        echo -e "  ${CYAN}│${RESET}  ip6tables  : ${BOLD}/etc/iptables/rules.v6${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────${RESET}" | tee -a "$LOG_FILE"
    echo ""

    # iptables verification
    if [[ "$HAS_IPV4" == "true" ]] && command -v iptables &>/dev/null; then
        echo -e "  ${BOLD}${CYAN}┌─ تأیید iptables ─────────────────────────────────${RESET}" | tee -a "$LOG_FILE"
        set +e
        local tcpmss_v4
        tcpmss_v4=$(iptables -t mangle -L POSTROUTING -n -v 2>/dev/null \
            | grep "TCPMSS" || true)
        set -e
        if [[ -n "$tcpmss_v4" ]]; then
            while IFS= read -r rule_line; do
                echo -e "  ${CYAN}│${RESET}  ${DIM}$rule_line${RESET}" | tee -a "$LOG_FILE"
            done <<< "$tcpmss_v4"
        else
            echo -e "  ${CYAN}│${RESET}  ${DIM}(هیچ قانونی پیدا نشد)${RESET}" | tee -a "$LOG_FILE"
        fi
        echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────${RESET}" | tee -a "$LOG_FILE"
        echo ""
    fi

    # REBOOT notice
    if [[ "$XANMOD_INSTALLED" == "true" ]] || [[ "$PHASE_XANMOD" == "done" ]]; then
        echo ""
        _hr "═" "$YELLOW"
        echo -e "${BOLD}${YELLOW}" | tee -a "$LOG_FILE"
        echo "  ██████╗ ███████╗██████╗  ██████╗  ██████╗ ████████╗" | tee -a "$LOG_FILE"
        echo "  ██╔══██╗██╔════╝██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝" | tee -a "$LOG_FILE"
        echo "  ██████╔╝█████╗  ██████╔╝██║   ██║██║   ██║   ██║   " | tee -a "$LOG_FILE"
        echo "  ██╔══██╗██╔══╝  ██╔══██╗██║   ██║██║   ██║   ██║   " | tee -a "$LOG_FILE"
        echo "  ██║  ██║███████╗██████╔╝╚██████╔╝╚██████╔╝   ██║   " | tee -a "$LOG_FILE"
        echo "  ╚═╝  ╚═╝╚══════╝╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   " | tee -a "$LOG_FILE"
        echo -e "${RESET}"
        echo -e "  ${BOLD}${YELLOW}⚡ XanMod نصب شد — برای فعال شدن BBRv3 باید reboot کنید${RESET}" | tee -a "$LOG_FILE"
        echo ""
        echo -e "     ${BOLD}sudo reboot${RESET}" | tee -a "$LOG_FILE"
        echo ""
        echo -e "  ${DIM}بعد از reboot، تأیید:${RESET}" | tee -a "$LOG_FILE"
        echo -e "    ${CYAN}uname -r${RESET}                                  ${DIM}# باید xanmod باشد${RESET}" | tee -a "$LOG_FILE"
        echo -e "    ${CYAN}sysctl net.ipv4.tcp_congestion_control${RESET}    ${DIM}# باید bbr باشد${RESET}" | tee -a "$LOG_FILE"
        _hr "═" "$YELLOW"
        echo ""
    fi

    echo -e "  ${DIM}فایل لاگ : ${LOG_FILE}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${DIM}شروع     : ${SCRIPT_START}${RESET}" | tee -a "$LOG_FILE"
    echo -e "  ${DIM}پایان    : $(date '+%Y-%m-%d %H:%M:%S')${RESET}" | tee -a "$LOG_FILE"
    echo ""
    echo -e "${BOLD}${CYAN}${divider}${RESET}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
_print_banner() {
    local divider
    divider=$(printf "%${TERM_WIDTH}s" | tr ' ' '═')

    echo -e "${BOLD}${CYAN}"
    echo "$divider"
    echo ""
    echo "   ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗"
    echo "   ██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
    echo "   ███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
    echo "   ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
    echo "   ███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
    echo "   ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
    echo ""
    echo -e "   ${WHITE}███████╗███████╗████████╗██╗   ██╗██████╗ ${CYAN}"
    echo -e "   ${WHITE}██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗${CYAN}"
    echo -e "   ${WHITE}███████╗█████╗     ██║   ██║   ██║██████╔╝${CYAN}"
    echo -e "   ${WHITE}╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ ${CYAN}"
    echo -e "   ${WHITE}███████║███████╗   ██║   ╚██████╔╝██║     ${CYAN}"
    echo -e "   ${WHITE}╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     ${CYAN}"
    echo ""
    echo "$divider"
    echo -e "${RESET}"
    echo -e "  ${BOLD}اسکریپت راه‌اندازی خودکار سرور — نسخه ${SCRIPT_VERSION}${RESET}"
    echo -e "  ${DIM}هدف: بهینه‌سازی لینوکس برای محیط‌های VPN/Proxy${RESET}"
    echo -e "  ${DIM}پشتیبانی: Debian / Ubuntu | معماری: x86_64${RESET}"
    echo ""
    _hr "─" "$CYAN"
    echo ""
}

main() {
    mkdir -p /var/log 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/server-setup.log"
        touch "$LOG_FILE"
        echo "هشدار: /var/log در دسترس نیست — لاگ در $LOG_FILE"
    fi

    _print_banner

    phase_env
    phase_resources
    phase_xanmod
    phase_sysctl
    phase_mtu
    phase_iptables
    phase_summary

    local has_critical_failure=false
    for chk_status in "$PHASE_ENV" "$PHASE_SYSCTL" "$PHASE_IPTABLES"; do
        if [[ "$chk_status" == "failed" ]]; then
            has_critical_failure=true
            break
        fi
    done

    if [[ "$has_critical_failure" == "true" ]]; then
        log_error "یک یا چند فاز حیاتی ناموفق — لاگ: ${BOLD}$LOG_FILE${RESET}"
        exit 1
    else
        log_ok "${BOLD}${GREEN}اسکریپت با موفقیت کامل شد${RESET}"
        exit 0
    fi
}

main "$@"
