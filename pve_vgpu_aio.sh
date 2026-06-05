#!/usr/bin/env bash
# ==============================================================================
# PVE AIO vGPU 一键部署脚本 v2.1
# 适配: Proxmox VE 8.3 | NVIDIA vGPU 550.90.05 | Debian 12 Bookworm | Turing/Ampere/Ada 优化
#
# 功能流程:
#   Phase 0: 环境检测 (PVE版本/GPU型号/内核)
#   Phase 1: 系统准备 (换源/IOMMU/依赖/禁用nouveau) → 重启
#   Phase 2: 驱动安装 (下载/打补丁/DKMS/vgpu_unlock-rs)
#   Phase 3: 授权服务 (FastAPI-DLS)
#   Phase 4: VM配置 (创建/挂载vGPU)
#   Phase 5: 验证报告
#
# 社区资源:
#   vgpu_unlock-rs:  https://github.com/mbilker/vgpu_unlock-rs
#   vgpu-proxmox:     https://gitlab.com/polloloco/vgpu-proxmox
#   FastAPI-DLS:      https://git.collinwebdesigns.de/oscar.krause/fastapi-dls
#   驱动存档:          https://github.com/nvidiavgpuarchive/index
#   Proxmox 官方教程:  https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE
# ==============================================================================

set -Euo pipefail
# 注意: 不用 set -e, apt update 遇到企业源401会返回非零但不算致命错误
# 各函数内部自行判断关键步骤的返回值

# ========================== 配置区 ==========================

# --- NVIDIA 驱动版本 ---
# 550.90.05 = NVIDIA vGPU 17.x Host Driver, 对应补丁 550.90.05.patch
NVIDIA_DRIVER_VER="550.90.05"
NVIDIA_VGPU_BRANCH="17.x"
NVIDIA_DRIVER_FILE="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VER}-vgpu-kvm.run"
NVIDIA_PATCH_FILE="${NVIDIA_DRIVER_VER}.patch"

# --- 驱动下载地址 ---
# 优先使用脚本同目录下 NVIDIA-GRID-*/Host_Drivers/ 中的本地驱动；
# 若只 curl 单脚本执行，则回退到 GitHub raw 下载。
DRIVER_DOWNLOAD_URL="https://gitee.com/kunkumo/pve/raw/master/NVIDIA-GRID-Linux-KVM-550.90.05-550.90.07-552.55/Host_Drivers/NVIDIA-Linux-x86_64-550.90.05-vgpu-kvm.run"

# --- 仓库地址 ---
VGPU_UNLOCK_RS_REPO="https://github.com/mbilker/vgpu_unlock-rs.git"
VGPU_PROXMOX_REPO="https://gitlab.com/polloloco/vgpu-proxmox.git"
FASTAPI_DLS_URL="https://git.collinwebdesigns.de/oscar.krause/fastapi-dls"

# --- APT 源 (清华镜像) ---
DEBIAN_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"
SEC_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian-security"
PVE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve"
DNS_LIST=("114.114.114.114" "223.5.5.5" "119.29.29.29")

# --- 路径 ---
BACKUP_DIR="/root/pve_vgpu_backup_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="/root/pve_vgpu_report_$(date +%Y%m%d_%H%M%S).txt"
VGPU_UNLOCK_DIR="/opt/vgpu_unlock-rs"
VGPU_PROXMOX_DIR="/opt/vgpu-proxmox"
STATE_FILE="/root/.pve_vgpu_aio_state"
DRIVER_CACHE="/root"
BUNDLED_DRIVER_DIR="NVIDIA-GRID-Linux-KVM-550.90.05-550.90.07-552.55/Host_Drivers"

# --- 模式标志 ---
APPLY=1
DRY_RUN=0
PHASE=""
SKIP_SOURCES=0
SKIP_IOMMU=0
SKIP_REBOOT=0
RESUME=0

# --- VM 配置 / 母机与克隆配置 ---
VMID=""
GPU_PCI=""
DISK_BY_ID=""
DISK_BUS="scsi1"
MDEV_PROFILE="${MDEV_PROFILE:-}"
VGPU_VRAM="${VGPU_VRAM:-1}"
CREATE_BASE=0
CLONE_RANGE=0
BASE_VMID="${BASE_VMID:-100}"
BASE_NAME="${BASE_NAME:-A1-base}"
BOOT_DISK_GB="${BOOT_DISK_GB:-60}"
DATA_DISK_GB="${DATA_DISK_GB:-256}"
VM_CPU="${VM_CPU:-6}"
VM_MEM_MB="${VM_MEM_MB:-8192}"
VM_STORAGE="${VM_STORAGE:-local}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_NET_MODEL="${VM_NET_MODEL:-e1000}"
VM_ISO="${VM_ISO:-}"
SRC_VMID="${SRC_VMID:-100}"
START_ID="${START_ID:-101}"
END_ID="${END_ID:-106}"
NAME_PREFIX="${NAME_PREFIX:-A1}"
WALLPAPER_NO="${WALLPAPER_NO:-1}"
START_AFTER=0
MERGE_LOCAL_LVM=0
ATTACH_VGPU=0

# ========================== 工具函数 ==========================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

log()      { echo -e "${GREEN}[$(date '+%F %T')]${NC} $*"; }
warn()     { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()      { echo -e "${RED}[ERROR]${NC} $*"; }
info()     { echo -e "${BLUE}[INFO]${NC} $*"; }
banner()   { echo -e "${CYAN}$*${NC}"; }

require_root() {
    [ "${EUID}" -eq 0 ] || { err "请用 root 用户执行此脚本"; exit 1; }
}

run_cmd() {
    printf "${CYAN}+ ${NC}" >&2
    printf '%q ' "$@" >&2
    echo >&2
    if [ "$APPLY" = "1" ]; then
        "$@"
    else
        warn "(预览模式，未实际执行)"
    fi
}

backup_file() {
    local f="$1"
    if [ -e "$f" ]; then
        mkdir -p "${BACKUP_DIR}$(dirname "$f")"
        cp -a "$f" "${BACKUP_DIR}${f}"
        log "已备份: $f → ${BACKUP_DIR}${f}"
    fi
}

get_codename() {
    . /etc/os-release 2>/dev/null || true
    echo "${VERSION_CODENAME:-bookworm}"
}

get_pve_version() {
    pveversion 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown"
}

get_kernel_version() {
    uname -r
}

# --- 状态持久化 (支持断点续传) ---
save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
PHASE=${1:-}
APPLY=${APPLY}
SKIP_SOURCES=${SKIP_SOURCES}
SKIP_IOMMU=${SKIP_IOMMU}
NVIDIA_DRIVER_VER=${NVIDIA_DRIVER_VER}
NVIDIA_DRIVER_FILE=${NVIDIA_DRIVER_FILE}
BACKUP_DIR=${BACKUP_DIR}
VMID=${VMID}
GPU_PCI=${GPU_PCI}
DISK_BY_ID=${DISK_BY_ID}
MDEV_PROFILE=${MDEV_PROFILE}
TIMESTAMP=$(date +%s)
EOF
}

load_state() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

# ========================== Phase 0: 环境检测 ==========================

detect_gpu() {
    log "检测 NVIDIA GPU..."
    if ! command -v lspci &>/dev/null; then
        run_cmd apt-get update -qq || true
        run_cmd apt-get install -y -qq pciutils
    fi

    local gpu_info
    gpu_info=$(lspci -nn 2>/dev/null | grep -i 'vga.*nvidia\|3D.*10de' || true)

    if [ -z "$gpu_info" ]; then
        err "未检测到 NVIDIA GPU!"
        warn "请确认显卡已正确安装。继续执行仅做系统准备工作。"
        GPU_ARCH="unknown"
        return 1
    fi

    echo "$gpu_info"
    echo

    # 提取设备ID并判断架构
    local dev_ids
    dev_ids=$(echo "$gpu_info" | grep -oP '\[\K10de:[0-9a-f]{4}(?=\])' | cut -d: -f2 | sort -u)
    local gpu_count; gpu_count=$(echo "$dev_ids" | wc -l)
    info "检测到 ${gpu_count} 个 NVIDIA GPU (VGA/3D)"

    local is_pascal=0
    local is_turing=0
    local is_ampere=0
    local is_ada=0

    for dev_id in $dev_ids; do
        case "$dev_id" in
            # Pascal (GTX 10xx / P4 / P40) — 550 系列已移除官方支持，通常建议改用 535.216.01
            1b00|1b02|1b06|1b30|1b80|1b81|1b82|1b83|1b84|1bb0|1bb1|1bb3|1c02|1c03|1c30)
                warn "  → dev $dev_id: Pascal (GTX 10xx / Quadro Pxx), 550.90.05 可能不支持，建议使用 535.216.01"
                is_pascal=1 ;;
            # Turing (GTX 16xx / RTX 20xx)
            1f02|1f06|1f07|1f08|1f09|1f0a|1f0b|1e02|1e04|1e07|1e30|1e81|1e82|1e84|1e87|1e89)
                info "  → dev $dev_id: Turing, 支持 550 vGPU ✓"
                is_turing=1 ;;
            # Ampere (RTX 30xx)
            2204|2206|2208|2205|2482|2484|2486|2488|2489|2501)
                warn "  → dev $dev_id: Ampere (RTX 30xx), vGPU 解锁可能不稳定"
                is_ampere=1 ;;
            # Ada Lovelace (RTX 40xx)
            2684|2702|2782|2785)
                warn "  → dev $dev_id: Ada (RTX 40xx), 社区支持有限"
                is_ada=1 ;;
            *)
                warn "  → dev $dev_id: 未知架构, 请确认兼容性" ;;
        esac
    done

    GPU_ARCH="pascal=${is_pascal} turing=${is_turing} ampere=${is_ampere} ada=${is_ada}"
    return 0
}

detect_system() {
    log "============================================"
    log "  PVE AIO vGPU 一键部署 v2.0 — 环境检测"
    log "============================================"
    echo

    local pve_ver; pve_ver=$(get_pve_version)
    local kernel_ver; kernel_ver=$(get_kernel_version)
    local codename; codename=$(get_codename)

    info "PVE 版本:     ${pve_ver:-未知}"
    info "内核版本:     ${kernel_ver}"
    info "Debian 代号:  ${codename}"
    info "目标驱动:     ${NVIDIA_DRIVER_VER} (vGPU ${NVIDIA_VGPU_BRANCH})"
    info "当前目录:     $(pwd)"
    echo

    # PVE 8.x 兼容性检查
    if [[ "$pve_ver" =~ ^8\. ]]; then
        info "PVE 8.x 检测通过 ✓"
    elif [[ "$pve_ver" =~ ^7\. ]]; then
        warn "PVE 7.x 检测到, 脚本针对 8.3 优化, 部分功能可能需要调整"
    else
        warn "无法确定 PVE 版本, 继续执行但请注意兼容性"
    fi

    # 内核版本检查
    local major minor
    major=$(echo "$kernel_ver" | cut -d. -f1)
    minor=$(echo "$kernel_ver" | cut -d. -f2)
    if [ "$major" -ge 6 ] && [ "$minor" -ge 5 ]; then
        info "内核 ${kernel_ver} 兼容 550 驱动 ✓"
    elif [ "$major" -ge 6 ]; then
        info "内核 ${kernel_ver} 应兼容 550 驱动"
    else
        warn "内核版本较旧, 建议升级到 PVE 8.3"
    fi

    echo
    detect_gpu
    echo

    # 检查是否是 i440fx 还是 q35 (vGPU 需要 q35)
    info "注意: vGPU 需要 VM 使用 q35 机型 + OVMF (UEFI) BIOS"
    info "如果你的 VM 之前是 i440fx, 需要重建或转换"
    echo
}

# ========================== Phase 1: 系统准备 ==========================

set_sources() {
    [ "$SKIP_SOURCES" = "1" ] && { log "跳过 APT 源配置"; return 0; }

    local codename; codename="$(get_codename)"
    log "配置 DNS / APT / PVE 源 (清华镜像)..."

    backup_file /etc/resolv.conf
    backup_file /etc/apt/sources.list
    backup_file /etc/apt/sources.list.d/pve-enterprise.list
    backup_file /etc/apt/sources.list.d/pve-no-subscription.list
    backup_file /etc/apt/sources.list.d/ceph.list

    if [ "$APPLY" = "1" ]; then
        # DNS
        { for d in "${DNS_LIST[@]}"; do echo "nameserver $d"; done; } > /etc/resolv.conf

        # Debian 基础源
        cat > /etc/apt/sources.list <<EOF
deb ${DEBIAN_MIRROR} ${codename} main contrib non-free non-free-firmware
deb ${DEBIAN_MIRROR} ${codename}-updates main contrib non-free non-free-firmware
deb ${SEC_MIRROR} ${codename}-security main contrib non-free non-free-firmware
EOF

        # 禁用所有企业源
        if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
            sed -i 's/^deb/# deb/g' /etc/apt/sources.list.d/pve-enterprise.list
        fi
        if [ -f /etc/apt/sources.list.d/ceph.list ]; then
            sed -i 's/^deb/# deb/g' /etc/apt/sources.list.d/ceph.list
        fi

        # 无订阅源
        cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb ${PVE_MIRROR} ${codename} pve-no-subscription
EOF

        log "APT 源配置完成"
        run_cmd apt update
    fi
}

install_dependencies() {
    log "安装编译依赖和内核头文件..."
    local kernel_headers="proxmox-headers-$(uname -r)"
    local packages=(
        git build-essential dkms mdevctl
        pve-headers proxmox-default-headers
        "$kernel_headers"
        curl wget pciutils
        jq
        # Rust 编译依赖
        pkg-config libssl-dev
        # FastAPI-DLS 依赖
        python3 python3-pip python3-venv
    )

    run_cmd apt update
    run_cmd apt install -y "${packages[@]}"

    # 验证 DKMS 可用
    if command -v dkms &>/dev/null; then
        info "DKMS 已就绪 ✓"
    else
        err "DKMS 安装失败!"
        return 1
    fi
}

configure_iommu() {
    [ "$SKIP_IOMMU" = "1" ] && { log "跳过 IOMMU 配置"; return 0; }

    local vendor param
    vendor="$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    if echo "$vendor" | grep -qi intel; then
        param="intel_iommu=on iommu=pt"
    else
        param="amd_iommu=on iommu=pt"
    fi

    log "配置 IOMMU 内核参数: $param"

    backup_file /etc/default/grub
    backup_file /etc/modules
    backup_file /etc/modprobe.d/pve-blacklist.conf

    if [ "$APPLY" = "1" ]; then
        # GRUB 内核参数
        if ! grep -q 'iommu=pt' /etc/default/grub; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$param /" /etc/default/grub
            log "GRUB IOMMU 参数已添加"
        else
            info "IOMMU 参数已存在, 跳过"
        fi

        # 所需内核模块
        local modules=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")
        for m in "${modules[@]}"; do
            grep -qxF "$m" /etc/modules 2>/dev/null || echo "$m" >> /etc/modules
        done
        log "VFIO 模块已添加到 /etc/modules"

        # 禁用 nouveau
        local bl="/etc/modprobe.d/pve-blacklist.conf"
        grep -qxF "blacklist nouveau" "$bl" 2>/dev/null || {
            cat >> "$bl" <<EOF

# --- vGPU AIO: 禁用 nouveau ---
blacklist nouveau
blacklist nvidiafb
options nouveau modeset=0
EOF
        }
        log "nouveau 已加入黑名单"

        # 更新 GRUB & initramfs
        run_cmd update-grub
        run_cmd update-initramfs -u -k all
    fi

    echo
    echo -e "${RED}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ⚠⚠⚠  需要重启!  ⚠⚠⚠                                   ║"
    echo "║  nouveau 已禁用, IOMMU 已配置, 重启后生效               ║"
    echo "║  重启后运行: bash $0 --resume                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ========================== Phase 2: 驱动安装 ==========================

install_rust() {
    log "安装/升级 Rust/Cargo，并配置国内 sparse 源..."

    if [ "$APPLY" != "1" ]; then
        run_cmd apt install -y curl git build-essential pkg-config libssl-dev
        return 0
    fi

    apt install -y curl git build-essential pkg-config libssl-dev cargo rustc || true

    # Debian 12 自带 cargo/rustc 偏旧，vgpu_unlock-rs 拉索引容易慢；优先使用 rustup + rsproxy。
    export RUSTUP_DIST_SERVER="https://rsproxy.cn"
    export RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
    if ! command -v "$HOME/.cargo/bin/cargo" >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://rsproxy.cn/rustup-init.sh | sh -s -- -y --profile minimal || true
    fi
    source "$HOME/.cargo/env" 2>/dev/null || true

    mkdir -p "$HOME/.cargo"
    cat > "$HOME/.cargo/config.toml" <<'EOF'
[source.crates-io]
replace-with = 'tuna'

[source.tuna]
registry = "sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"

[net]
git-fetch-with-cli = true
EOF

    cargo --version && rustc --version
    log "Rust/Cargo 已就绪，Cargo 源已切换为清华 sparse 镜像 ✓"
}

build_vgpu_unlock_rs() {
    log "编译 vgpu_unlock-rs (Rust LD_PRELOAD 解锁库)..."

    if [ "$APPLY" = "1" ]; then
        source "$HOME/.cargo/env" 2>/dev/null || true
        mkdir -p /opt

        if [ -d "$VGPU_UNLOCK_DIR" ]; then
            info "vgpu_unlock-rs 已存在, 拉取更新..."
            cd "$VGPU_UNLOCK_DIR"
            git pull --ff-only || true
        else
            git clone "$VGPU_UNLOCK_RS_REPO" "$VGPU_UNLOCK_DIR"
            cd "$VGPU_UNLOCK_DIR"
        fi

        cargo build --release 2>&1 | tail -5
        local so_file="${VGPU_UNLOCK_DIR}/target/release/libvgpu_unlock_rs.so"
        if [ -f "$so_file" ]; then
            log "vgpu_unlock-rs 编译成功: $so_file"
        else
            err "编译失败! 请检查 Rust/Cargo 环境"
            return 1
        fi
    else
        run_cmd mkdir -p /opt
        run_cmd git clone "$VGPU_UNLOCK_RS_REPO" "$VGPU_UNLOCK_DIR"
        run_cmd bash -c "cd $VGPU_UNLOCK_DIR && cargo build --release"
    fi
}

configure_vgpu_unlock() {
    log "配置 vgpu_unlock systemd 钩子..."

    if [ "$APPLY" = "1" ]; then
        local so_file="${VGPU_UNLOCK_DIR}/target/release/libvgpu_unlock_rs.so"

        mkdir -p /etc/vgpu_unlock
        if [ ! -f /etc/vgpu_unlock/profile_override.toml ]; then
            cat > /etc/vgpu_unlock/profile_override.toml <<'TOML'
# vgpu_unlock-rs profile override 配置
# 参考: https://github.com/mbilker/vgpu_unlock-rs
#
# 常用覆盖项 (取消注释以启用):
# [profile.nvidia-256]
# framebuffer = 0x1A0000000     # 帧缓存大小
# frl_enable = 60               # 帧率限制 (FRL)
# cuda = 1                      # 启用 CUDA (1=开, 0=关)
# num_displays = 4              # 最大显示器数
# max_resolution = [7680, 4320] # 最大分辨率
TOML
        fi
        log "profile_override.toml 已就绪"

        # systemd drop-in
        local preload_line="Environment=LD_PRELOAD=${so_file}"
        local services=("nvidia-vgpud" "nvidia-vgpu-mgr")

        for svc in "${services[@]}"; do
            mkdir -p "/etc/systemd/system/${svc}.service.d"
            cat > "/etc/systemd/system/${svc}.service.d/vgpu_unlock.conf" <<EOF
[Service]
${preload_line}
EOF
            log "已配置 ${svc} LD_PRELOAD 钩子"
        done

        systemctl daemon-reload
    fi
}

ensure_vgpu_runtime() {
    log "加载 nvidia-vgpu-vfio 并重启 vGPU 服务..."

    if [ "$APPLY" != "1" ]; then
        run_cmd modprobe nvidia-vgpu-vfio
        return 0
    fi

    # 这一步是 GTX 1060 / PVE 8.3 实测关键点：模块未加载时 mdevctl types 可能为空。
    mkdir -p /etc/modules-load.d
    cat > /etc/modules-load.d/nvidia-vgpu-vfio.conf <<'EOF'
nvidia-vgpu-vfio
EOF

    modprobe nvidia-vgpu-vfio 2>/dev/null || modprobe nvidia_vgpu_vfio 2>/dev/null || {
        err "无法加载 nvidia-vgpu-vfio 模块，请检查 custom.run / DKMS 是否安装到当前内核"
        modinfo nvidia-vgpu-vfio 2>/dev/null || modinfo nvidia_vgpu_vfio 2>/dev/null || true
        return 1
    }

    systemctl daemon-reload
    systemctl reset-failed nvidia-vgpud nvidia-vgpu-mgr 2>/dev/null || true
    rm -rf /var/run/nvidia-vgpud /var/run/nvidia-vgpu-mgr
    systemctl restart nvidia-vgpud 2>/dev/null || true
    systemctl restart nvidia-vgpu-mgr 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet nvidia-vgpu-mgr; then
        log "nvidia-vgpu-mgr 已运行 ✓"
    else
        warn "nvidia-vgpu-mgr 未保持运行，下面输出最近日志供排错"
        journalctl -u nvidia-vgpu-mgr -b --no-pager -n 80 -l || true
    fi

    if mdevctl types 2>/dev/null | grep -q 'nvidia-'; then
        log "mdevctl types 已出现 nvidia vGPU profile ✓"
        mdevctl types | sed -n '1,80p'
    else
        warn "mdevctl types 暂无 nvidia profile；可尝试 reboot 后再查"
        find /sys/bus/pci/devices/ -maxdepth 3 -type d -name 'mdev_supported_types' -print || true
    fi
}

fetch_driver_patch() {
    log "获取 NVIDIA ${NVIDIA_DRIVER_VER} 驱动补丁..."

    if [ "$APPLY" = "1" ]; then
        if [ -d "$VGPU_PROXMOX_DIR" ]; then
            info "vgpu-proxmox 已存在, 拉取更新..."
            cd "$VGPU_PROXMOX_DIR"
            git pull --ff-only || true
        else
            git clone "$VGPU_PROXMOX_REPO" "$VGPU_PROXMOX_DIR"
            cd "$VGPU_PROXMOX_DIR"
        fi

        local patch_path="${VGPU_PROXMOX_DIR}/${NVIDIA_PATCH_FILE}"
        if [ -f "$patch_path" ]; then
            log "补丁文件已就绪: $patch_path"
        else
            err "未找到 ${NVIDIA_PATCH_FILE}!"
            err "可用的 550 系列补丁:"
            ls -1 "${VGPU_PROXMOX_DIR}"/550.*.patch 2>/dev/null || warn "  (无匹配的 550 补丁, 仓库可能已更新)"
            warn "请检查 https://gitlab.com/polloloco/vgpu-proxmox 获取最新补丁列表"
            return 1
        fi
    else
        run_cmd git clone "$VGPU_PROXMOX_REPO" "$VGPU_PROXMOX_DIR"
    fi
}

cleanup_nvidia_installer_state() {
    log "检查 NVIDIA 安装器残留状态..."

    if [ "$APPLY" != "1" ]; then
        run_cmd rm -rf /var/lib/nvidia
        run_cmd mkdir -p /var/lib/nvidia
        return 0
    fi

    if [ -e /var/lib/nvidia/log ] || [ -d /var/lib/nvidia ]; then
        local backup_dir="/root/nvidia-installer-state-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp -a /var/lib/nvidia "$backup_dir/" 2>/dev/null || true
        rm -rf /var/lib/nvidia
        log "已备份并清理 NVIDIA 安装器残留: $backup_dir"
    fi

    mkdir -p /var/lib/nvidia
}

install_nvidia_driver() {
    local driver_path="${DRIVER_CACHE}/${NVIDIA_DRIVER_FILE}"
    local script_dir bundled_driver
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bundled_driver="${script_dir}/${BUNDLED_DRIVER_DIR}/${NVIDIA_DRIVER_FILE}"

    log "============================================"
    log "  NVIDIA vGPU 驱动安装"
    log "  版本: ${NVIDIA_DRIVER_VER} (vGPU ${NVIDIA_VGPU_BRANCH})"
    log "============================================"

    # 检查驱动文件是否存在，不存在则自动下载
    if [ ! -f "$driver_path" ]; then
        if [ -f "$bundled_driver" ]; then
            driver_path="$bundled_driver"
            log "使用随脚本打包的 Host Driver: $driver_path"
        else
            warn "驱动文件未找到: ${DRIVER_CACHE}/${NVIDIA_DRIVER_FILE}"
            warn "随脚本打包驱动也未找到: $bundled_driver"
            log "尝试自动下载..."

            if [ -n "${DRIVER_DOWNLOAD_URL:-}" ]; then
                log "下载地址: ${DRIVER_DOWNLOAD_URL}"
                if [ "$APPLY" = "1" ]; then
                    wget -q --show-progress -O "$driver_path" "$DRIVER_DOWNLOAD_URL" || {
                        err "wget 下载失败, 尝试 curl..."
                        curl -L --progress-bar -o "$driver_path" "$DRIVER_DOWNLOAD_URL" || {
                            err "自动下载失败! 请手动下载驱动"
                            err "下载地址: ${DRIVER_DOWNLOAD_URL}"
                            err "放置到: ${driver_path}"
                            return 1
                        }
                    }
                    log "驱动下载完成 ✓"
                else
                    run_cmd wget -O "$driver_path" "$DRIVER_DOWNLOAD_URL"
                fi
            else
                err "未配置驱动下载地址, 无法自动下载"
                warn "请手动下载驱动放置到: ${driver_path}"
                return 1
            fi
        fi
    else
        log "驱动文件已找到: $driver_path"
    fi

    if [ "$APPLY" = "1" ]; then
        chmod +x "$driver_path"
        cleanup_nvidia_installer_state

        local patch_path="${VGPU_PROXMOX_DIR}/${NVIDIA_PATCH_FILE}"
        local custom_driver="${driver_path//-vgpu-kvm.run/-vgpu-kvm-custom.run}"

        if [ -f "$patch_path" ]; then
            log "应用补丁: ${NVIDIA_PATCH_FILE}"
            # 先 cd 到驱动所在目录，确保 custom.run 输出到正确位置
            cd "$(dirname "$driver_path")"
            run_cmd bash "$driver_path" --apply-patch "$patch_path"

            # 检查补丁是否成功生成了 custom.run
            if [ -f "$custom_driver" ]; then
                log "补丁应用成功, 安装 custom 驱动: ${custom_driver##*/}"
                chmod +x "$custom_driver"
                cleanup_nvidia_installer_state
                run_cmd bash "$custom_driver" --silent --accept-license --dkms -m=kernel
            else
                err "补丁应用失败! 未生成 custom.run 文件"
                err "请检查驱动版本是否与补丁匹配: ${NVIDIA_DRIVER_VER} ↔ ${NVIDIA_PATCH_FILE}"
                return 1
            fi
        else
            err "补丁文件未找到: ${patch_path}"
            err "消费级显卡必须打补丁才能开启 vGPU, 不能直接安装!"
            err "请确保 vgpu-proxmox 仓库已克隆且补丁文件存在"
            return 1
        fi

        # 配置 nvidia-persistenced
        log "配置 nvidia-persistenced..."
        if [ -f /usr/bin/nvidia-persistenced ]; then
            run_cmd systemctl enable nvidia-persistenced
            run_cmd systemctl start nvidia-persistenced
        fi

        log "NVIDIA 驱动安装完成!"
    else
        run_cmd bash "$driver_path" --apply-patch "${VGPU_PROXMOX_DIR}/${NVIDIA_PATCH_FILE}"
        run_cmd bash "$driver_path" --silent --accept-license --dkms
    fi
}

verify_driver() {
    log "验证驱动安装..."

    if [ "$APPLY" = "1" ]; then
        if command -v nvidia-smi &>/dev/null; then
            echo
            nvidia-smi
            echo
            log "nvidia-smi 可正常执行 ✓"
        else
            warn "nvidia-smi 不可用, 可能需要重启"
            warn "请重启后运行: nvidia-smi 验证"
        fi

        # 检查 vGPU 类型是否可用
        if [ -d /sys/class/mdev_bus ]; then
            info "MDEV 总线可用, vGPU 已就绪 ✓"
        else
            warn "MDEV 总线不可用, 请确认:"
            warn "  1. 是否已重启"
            warn "  2. IOMMU 是否已启用"
            warn "  3. 运行: dmesg | grep -i nvidia"
        fi
    fi
}

# ========================== Phase 3: FastAPI-DLS 授权服务 ==========================

detect_pve_lan_ip() {
    local ip=""

    # 优先取默认路由出口 IP，最接近 PVE Web 管理地址。
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')

    # 兜底：取 vmbr0 的 IPv4。
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show vmbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    fi

    # 再兜底：取第一块非 lo 的 IPv4。
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    [ -n "$ip" ] || ip="127.0.0.1"
    echo "$ip"
}

install_fastapi_dls() {
    log "部署 FastAPI-DLS 授权服务..."

    if [ "$APPLY" = "1" ]; then
        # 下载最新 deb 包
        local deb_file="/tmp/fastapi-dls.deb"
        local dls_ip
        dls_ip="$(detect_pve_lan_ip)"
        log "FastAPI-DLS 将使用 PVE IP: ${dls_ip}"

        if [ ! -f "$deb_file" ]; then
            log "下载 FastAPI-DLS deb 包..."
            # 尝试从官方 registry 获取最新版本
            # 注意: 具体 URL 可能随版本变化
            local dls_url="${FASTAPI_DLS_URL}/-/package_files/233/download"
            wget -q --show-progress -O "$deb_file" "$dls_url" || {
                warn "默认 URL 下载失败, 尝试从 Docker Hub 部署..."
                install_fastapi_dls_docker
                return
            }
        fi

        run_cmd dpkg -i "$deb_file" || run_cmd apt-get install -f -y --fix-missing

        # 配置环境变量
        if [ ! -f /etc/fastapi-dls/env ]; then
            mkdir -p /etc/fastapi-dls
            cat > /etc/fastapi-dls/env <<EOF
DLS_URL=${dls_ip}
DLS_PORT=443
LEASE_EXPIRE_DAYS=90
RENEW_DAYS=30
INSTANCE_REF="Proxmox VE 8.3 vGPU Host"
EOF
            log "FastAPI-DLS 环境配置已创建"
        fi

        run_cmd systemctl enable --now fastapi-dls.service
        log "FastAPI-DLS 服务已启动"
        log "Windows 客户端授权地址: https://${dls_ip}:443/-/client-token"

        # 检查服务状态
        sleep 2
        if systemctl is-active --quiet fastapi-dls.service; then
            log "FastAPI-DLS 运行正常 ✓"
        else
            warn "FastAPI-DLS 启动失败, 请检查: systemctl status fastapi-dls"
        fi
    else
        run_cmd wget -O /tmp/fastapi-dls.deb "${FASTAPI_DLS_URL}/-/package_files/233/download"
        run_cmd dpkg -i /tmp/fastapi-dls.deb
    fi
}

install_fastapi_dls_docker() {
    log "通过 Docker 部署 FastAPI-DLS..."
    run_cmd apt-get install -y docker.io docker-compose

    local dls_ip
    dls_ip="$(detect_pve_lan_ip)"
    log "Docker FastAPI-DLS 将使用 PVE IP: ${dls_ip}"

    if [ "$APPLY" = "1" ]; then
        mkdir -p /opt/fastapi-dls
        cat > /opt/fastapi-dls/docker-compose.yml <<YAML
version: '3.8'
services:
  fastapi-dls:
    image: collinwebdesigns/fastapi-dls:latest
    container_name: fastapi-dls
    restart: unless-stopped
    ports:
      - "443:443"
    environment:
      DLS_URL: ${dls_ip}
      DLS_PORT: 443
      LEASE_EXPIRE_DAYS: 90
      RENEW_DAYS: 30
    volumes:
      - /opt/fastapi-dls/data:/app/data
YAML
        cd /opt/fastapi-dls
        run_cmd docker-compose up -d
        log "Docker FastAPI-DLS 已启动"
        log "Windows 客户端授权地址: https://${dls_ip}:443/-/client-token"
    fi
}

# ========================== Phase 4: VM 配置 ==========================

vram_to_mb_main() {
    local v="${1,,}"
    v="${v// /}"
    if [[ "$v" =~ ^([0-9]+)(g|gb|gib)$ ]]; then
        echo "$((${BASH_REMATCH[1]} * 1024))"
    elif [[ "$v" =~ ^([0-9]+)(m|mb|mib)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$v" =~ ^([0-9]+)\.([0-9]+)(g|gb|gib)?$ ]]; then
        awk -v n="$v" 'BEGIN{printf "%d", n*1024}'
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
        [ "$v" -le 64 ] && echo "$((v * 1024))" || echo "$v"
    else
        err "显存参数格式错误: $1，示例: --vram 1 / --vram 1.2 / --vram 1200M"
        return 1
    fi
}

resolve_vgpu_for_existing_vm() {
    local want_mb best_diff best_pci best_profile best_fb
    local cur_pci cur_profile cur_fb cur_avail line diff

    if [ -n "$MDEV_PROFILE" ]; then
        mdevctl types 2>/dev/null | grep -q "$MDEV_PROFILE" || {
            err "没有检测到 mdev profile: $MDEV_PROFILE"
            return 1
        }
        if [ -z "$GPU_PCI" ]; then
            GPU_PCI=$(mdevctl types 2>/dev/null | awk 'p&&/^0000:/{exit} /^0000:/{pci=$1} $1==p{print pci; exit}' p="$MDEV_PROFILE")
        fi
        [ -n "$GPU_PCI" ] || { err "无法从 mdevctl types 找到 ${MDEV_PROFILE} 对应的 PCI 地址"; return 1; }
        return 0
    fi

    want_mb=$(vram_to_mb_main "$VGPU_VRAM") || return 1
    best_diff=999999999
    best_pci=""; best_profile=""; best_fb=""
    cur_pci=""; cur_profile=""; cur_fb=""; cur_avail=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9a-fA-F]{4}: ]]; then
            cur_pci="${line%% *}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]+(nvidia-[0-9]+) ]]; then
            cur_profile="${BASH_REMATCH[1]}"
            cur_fb=""
            cur_avail=0
            continue
        fi
        if [[ "$line" =~ Available[[:space:]]instances:[[:space:]]*([0-9]+) ]]; then
            cur_avail="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ framebuffer=([0-9]+)([MG]) ]]; then
            cur_fb="${BASH_REMATCH[1]}"
            [ "${BASH_REMATCH[2]}" = "G" ] && cur_fb="$((cur_fb * 1024))"
        fi
        if [ -n "$cur_pci" ] && [ -n "$cur_profile" ] && [ -n "$cur_fb" ] && [ "${cur_avail:-0}" -gt 0 ]; then
            [ -z "$GPU_PCI" ] || [ "$cur_pci" = "$GPU_PCI" ] || continue
            if [ "$cur_fb" -ge "$want_mb" ]; then diff=$((cur_fb - want_mb)); else diff=$((999999 + want_mb - cur_fb)); fi
            if [ "$diff" -lt "$best_diff" ]; then
                best_diff="$diff"; best_pci="$cur_pci"; best_profile="$cur_profile"; best_fb="$cur_fb"
            fi
        fi
    done < <(mdevctl types 2>/dev/null)

    [ -n "$best_profile" ] || { err "找不到可用的 ${VGPU_VRAM} 显存 vGPU profile；请先运行 mdevctl types 查看"; return 1; }
    GPU_PCI="$best_pci"
    MDEV_PROFILE="$best_profile"
    info "自动选择 vGPU: ${GPU_PCI},mdev=${MDEV_PROFILE}, framebuffer=${best_fb}M"
}

configure_vm() {
    [ -n "$VMID" ] || return 0
    log "只给现有 VM ${VMID} 设置 vGPU，不修改 machine/bios/cpu/磁盘/网卡等配置..."

    command -v qm >/dev/null || { err "未找到 qm，请在 PVE 宿主机执行"; return 1; }
    qm status "$VMID" >/dev/null 2>&1 || { err "VMID ${VMID} 不存在"; return 1; }
    resolve_vgpu_for_existing_vm || return 1

    run_cmd qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1,mdev=${MDEV_PROFILE}"
    log "VM ${VMID} vGPU 设置完成: ${GPU_PCI},mdev=${MDEV_PROFILE}"
}

run_create_base_from_main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # 主脚本不干预母机脚本的 GPU/vGPU 选择逻辑；母机脚本自己负责菜单、显存、PCI、mdev。
    local args=(--vmid "$BASE_VMID" --name "$BASE_NAME" --cpu "$VM_CPU" --mem "$VM_MEM_MB" --boot-disk "$BOOT_DISK_GB" --data-disk "$DATA_DISK_GB" --storage "$VM_STORAGE" --bridge "$VM_BRIDGE" --net "$VM_NET_MODEL" --cpu-model "Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz")
    [ -n "$VM_ISO" ] && args+=(--iso "$VM_ISO")
    bash "$script_dir/pve_create_base_vm.sh" "${args[@]}"
}

run_merge_local_lvm_from_main() {
    log "检查并自动合并 local-lvm 到 local..."

    command -v pvesm >/dev/null || { warn "未找到 pvesm，跳过 local-lvm 合并"; return 0; }
    command -v lvs >/dev/null || { warn "未找到 lvs，跳过 local-lvm 合并"; return 0; }

    # local 默认允许 images，合并后 VM 磁盘直接放 /var/lib/vz/images
    pvesm set local --content backup,iso,vztmpl,rootdir,images,snippets 2>/dev/null || true

    if ! lvs --noheadings -o lv_name pve 2>/dev/null | awk '{print $1}' | grep -qx data; then
        info "未发现 pve/data(local-lvm)，看起来已经合并过了"
        return 0
    fi

    if pvesm status 2>/dev/null | awk '{print $1}' | grep -qx local-lvm; then
        local used
        used=$(pvesm list local-lvm 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
        if [ "${used:-0}" -gt 0 ]; then
            err "local-lvm 里还有 ${used} 个磁盘/镜像，不能自动删除合并。请先迁移或删除这些 VM 磁盘。"
            return 1
        fi
        run_cmd pvesm remove local-lvm
    fi

    if lvs --noheadings -o lv_name pve 2>/dev/null | awk '{print $1}' | grep -qx data; then
        log "删除空的 thinpool: /dev/pve/data"
        run_cmd lvremove -y /dev/pve/data
    fi

    local free_extents
    free_extents=$(vgs --noheadings -o vg_free_count pve 2>/dev/null | awk '{print $1+0}')
    if [ "${free_extents:-0}" -gt 0 ]; then
        log "把 VG 剩余空间扩容到 /dev/pve/root"
        run_cmd lvextend -l +100%FREE /dev/pve/root
        case "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" in
            xfs) run_cmd xfs_growfs / ;;
            *)   run_cmd resize2fs /dev/pve/root ;;
        esac
    else
        info "VG 已无空闲空间，无需扩容 root"
    fi

    log "local-lvm 合并检查完成；local 已支持 images/snippets/iso。"
}

run_clone_range_from_main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local args=(--src "$SRC_VMID" --start "$START_ID" --end "$END_ID" --prefix "$NAME_PREFIX" --wall "$WALLPAPER_NO" --cpu "$VM_CPU" --mem "$VM_MEM_MB" --bridge "$VM_BRIDGE" --net "$VM_NET_MODEL" --gpu "${GPU_PCI:-0000:03:00.0}" --vram "$VGPU_VRAM" --cpu-model "Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz")
    [ -n "$MDEV_PROFILE" ] && args+=(--mdev "$MDEV_PROFILE")
    [ -n "$VM_STORAGE" ] && args+=(--storage "$VM_STORAGE")
    [ "$START_AFTER" = "1" ] && args+=(--start-after)
    bash "$script_dir/pve_batch_clone.sh" "${args[@]}"
}

# ========================== Phase 5: 验证报告 ==========================

generate_report() {
    log "生成部署报告: $REPORT_FILE"

    {
        echo "=============================================="
        echo "  PVE AIO vGPU 部署报告"
        echo "  时间: $(date)"
        echo "=============================================="
        echo
        echo "[ 系统信息 ]"
        echo "  PVE 版本:   $(get_pve_version)"
        echo "  内核版本:   $(get_kernel_version)"
        echo "  Debian:     $(get_codename)"
        echo "  内核命令行: $(cat /proc/cmdline 2>/dev/null)"
        echo
        echo "[ GPU 信息 ]"
        lspci -nn | grep -i nvidia || echo "  (无 NVIDIA GPU 检测到)"
        echo
        echo "[ NVIDIA 驱动 ]"
        nvidia-smi 2>/dev/null || echo "  (nvidia-smi 不可用)"
        echo
        echo "[ vGPU 状态 ]"
        ls -la /sys/class/mdev_bus/ 2>/dev/null || echo "  (MDEV 总线不可用)"
        echo
        echo "[ IOMMU 状态 ]"
        dmesg 2>/dev/null | grep -i 'iommu\|vfio' | tail -20 || echo "  (无 IOMMU/VFIO 日志)"
        echo
        echo "[ FastAPI-DLS ]"
        systemctl status fastapi-dls 2>/dev/null | head -10 || echo "  (FastAPI-DLS 未安装)"
        echo
        echo "[ vGPU Unlock ]"
        echo "  vgpu_unlock-rs: ${VGPU_UNLOCK_DIR}"
        ls -la "${VGPU_UNLOCK_DIR}/target/release/libvgpu_unlock_rs.so" 2>/dev/null || echo "  (未编译)"
        echo
        echo "[ 可用的 vGPU 类型 ]"
        mdevctl types 2>/dev/null || echo "  (mdevctl 不可用)"
        echo
        echo "=============================================="
    } > "$REPORT_FILE"

    cat "$REPORT_FILE"
}

# ========================== 使用说明 ==========================

usage() {
    cat <<EOF
用法:
  bash $(basename "$0")                           # [一键模式] 全自动部署, 无需确认
  bash $(basename "$0") --detect                  # 仅检测系统环境
  bash $(basename "$0") --dry-run                 # 预览模式 (不执行写入)
  bash $(basename "$0") --resume                  # 从断点恢复
  bash $(basename "$0") --phase <N>               # 仅执行指定阶段
  bash $(basename "$0") --merge-local-lvm          # 删除 local-lvm 并合并到 local，危险操作
  bash $(basename "$0") --create-base --base-vmid 100 --base-name A1母机  # 一键创建母机
  bash $(basename "$0") --clone-range --src 100 --start 101 --end 106 --prefix A1 --mdev nvidia-524  # 一键克隆
  bash $(basename "$0") --vmid <ID> --gpu <PCI> --mdev nvidia-524  # 配置 VM

阶段说明:
  Phase 0: 环境检测 (PVE版本 / GPU型号 / 内核)
  Phase 1: 系统准备 (换源 + IOMMU + 依赖 + 禁用nouveau) → 需重启
  Phase 2: 驱动安装 (下载/打补丁/DKMS/vgpu_unlock-rs)
  Phase 3: 授权服务 (FastAPI-DLS)
  Phase 4: VM 配置
  Phase 5: 验证报告

选项:
  --dry-run        预览模式 (只显示命令, 不执行)
  
  --detect         仅检测环境, 不执行部署
  --resume         从上次中断处继续
  --phase <0-5>    执行指定阶段
  --skip-sources   跳过换源步骤
  --skip-iommu     跳过 IOMMU 配置
  --driver-ver X   指定驱动版本 (默认: ${NVIDIA_DRIVER_VER})
  --driver-file F  指定本地驱动文件路径
  --vmid ID        要配置的 VM ID
  --gpu PCI        GPU PCI 地址 (如 0000:01:00.0)
  --disk ID        直通磁盘 by-id (如 ata-xxx)
  --disk-bus BUS   磁盘总线 (默认: scsi1)
  --create-base    按截图标准一键创建母机：SeaBIOS/q35/sata0 60G/sata1 256G/e1000/audio0
  --clone-range    按截图标准批量克隆并挂载 vGPU mdev
  --merge-local-lvm 危险：删除 local-lvm/pve-data，并把空间合并进 local
  --base-vmid ID   母机 VMID，默认 100
  --base-name NAME 母机名称，默认 A1-base
  --boot-disk GB   母机系统盘，默认 60G
  --data-disk GB   母机数据盘，默认 256G
  --src ID         克隆来源母机 VMID，默认 100
  --start ID       克隆开始 VMID，默认 101
  --end ID         克隆结束 VMID，默认 106
  --prefix NAME    克隆名称前缀，默认 A1
  --wall N         壁纸序号备注，默认 1
  -h, --help       显示此帮助

示例:
  # 完整部署 (推荐流程)
  bash $(basename "$0")                              # 第一次: 系统准备 + 提示驱动位置
  [重启 PVE]
  bash $(basename "$0") --resume                     # 第二次: 安装驱动 + 解锁 + 授权

  # 仅检测环境
  bash $(basename "$0") --detect

  # 使用本地已下载的驱动文件
  bash $(basename "$0") --driver-file /root/NVIDIA-Linux-x86_64-550.90.05-vgpu-kvm.run

社区参考:
  - Proxmox Wiki:    https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE
  - vgpu_unlock-rs:  https://github.com/mbilker/vgpu_unlock-rs
  - vgpu-proxmox:    https://gitlab.com/polloloco/vgpu-proxmox
  - FastAPI-DLS:     https://git.collinwebdesigns.de/oscar.krause/fastapi-dls
  - 驱动存档:         https://github.com/nvidiavgpuarchive/index
  - 中文教程参考:     https://www.geekxw.top/2280/
EOF
}

# ========================== 参数解析 ==========================

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --apply)          APPLY=1; DRY_RUN=0; shift ;;
            --dry-run)        APPLY=0; DRY_RUN=1; shift ;;
            --detect)         PHASE="detect"; shift ;;
            --resume)         RESUME=1; shift ;;
            --phase)          PHASE="${2:-}"; shift 2 ;;
            --skip-sources)   SKIP_SOURCES=1; shift ;;
            --skip-iommu)     SKIP_IOMMU=1; shift ;;
            --driver-ver)     NVIDIA_DRIVER_VER="${2}"; NVIDIA_DRIVER_FILE="NVIDIA-Linux-x86_64-${2}-vgpu-kvm.run"; NVIDIA_PATCH_FILE="${2}.patch"; shift 2 ;;
            --driver-file)    DRIVER_CACHE="$(dirname "${2}")"; NVIDIA_DRIVER_FILE="$(basename "${2}")"; shift 2 ;;
            --vmid)           VMID="${2:-}"; shift 2 ;;
            --attach-vgpu)    ATTACH_VGPU=1; shift ;;
            --gpu)            GPU_PCI="${2:-}"; shift 2 ;;
            --disk)           DISK_BY_ID="${2:-}"; shift 2 ;;
            --disk-bus)       DISK_BUS="${2:-}"; shift 2 ;;
            --mdev)           MDEV_PROFILE="${2:-}"; shift 2 ;;
            --vram|--vram-gb) VGPU_VRAM="${2:-}"; shift 2 ;;
            --create-base)    CREATE_BASE=1; shift ;;
            --clone-range)    CLONE_RANGE=1; shift ;;
            --merge-local-lvm) MERGE_LOCAL_LVM=1; shift ;;
            --base-vmid)      BASE_VMID="${2:-}"; shift 2 ;;
            --base-name)      BASE_NAME="${2:-}"; shift 2 ;;
            --boot-disk)      BOOT_DISK_GB="${2:-}"; shift 2 ;;
            --data-disk)      DATA_DISK_GB="${2:-}"; shift 2 ;;
            --storage)        VM_STORAGE="${2:-}"; shift 2 ;;
            --bridge)         VM_BRIDGE="${2:-}"; shift 2 ;;
            --net)            VM_NET_MODEL="${2:-}"; shift 2 ;;
            --iso)            VM_ISO="${2:-}"; shift 2 ;;
            --src)            SRC_VMID="${2:-}"; shift 2 ;;
            --start)          START_ID="${2:-}"; shift 2 ;;
            --end)            END_ID="${2:-}"; shift 2 ;;
            --prefix)         NAME_PREFIX="${2:-}"; shift 2 ;;
            --wall)           WALLPAPER_NO="${2:-}"; shift 2 ;;
            --cpu)            VM_CPU="${2:-}"; shift 2 ;;
            --mem)            VM_MEM_MB="${2:-}"; shift 2 ;;
            --start-after)    START_AFTER=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                warn "未知参数: $1"; usage; exit 1 ;;
        esac
    done
}

# ========================== 主流程 ==========================

main() {
    require_root

    # 无参数默认: 全自动一键部署
    if [ "$#" -eq 0 ]; then
        echo
        banner "╔══════════════════════════════════════════════════════════╗"
        banner "║     PVE AIO vGPU 一键部署 v2.0                           ║"
        banner "║     目标: Proxmox VE 8.3 + NVIDIA vGPU 550.90.05                       ║"
        banner "║     模式: 全自动 (Ctrl+C 取消)                            ║"
        banner "╚══════════════════════════════════════════════════════════╝"
        echo
        detect_system
        APPLY=1
        PHASE="all"
    else
        parse_args "$@"
        [ "$RESUME" = "1" ] && load_state
        if [ "$MERGE_LOCAL_LVM" = "1" ]; then
            run_merge_local_lvm_from_main
            exit 0
        fi
        if [ "$CREATE_BASE" = "1" ]; then
            run_create_base_from_main
            exit 0
        fi
        if [ "$CLONE_RANGE" = "1" ]; then
            run_clone_range_from_main
            exit 0
        fi
    fi

    # ==== Phase: detect ====
    if [ "$PHASE" = "detect" ] || { [ "$#" -eq 0 ] && [ -z "$PHASE" ]; }; then
        detect_system
        [ "$PHASE" = "detect" ] && exit 0
    fi

    # 如果是一键模式, 执行全部
    [ "$#" -eq 0 ] && PHASE="all"

    # ==== Phase 1: 系统准备 ====
    if [ "$PHASE" = "all" ] || [ "$PHASE" = "1" ]; then
        echo
        log "============================================"
        log "  Phase 1: 系统准备"
        log "============================================"
        # 空 PVE 首次部署时自动把 local-lvm 合并到 local；如果 local-lvm 有磁盘，会安全停止并报错。
        run_merge_local_lvm_from_main
        set_sources
        install_dependencies
        configure_iommu
        save_state "2"
        echo
        warn "Phase 1 完成. 请重启系统, 然后运行:"
        warn "  bash $0 --resume"
        warn "继续 Phase 2 (驱动安装)"
        warn "=============================================="
        warn ""
        [ "$PHASE" = "1" ] && exit 0
        # 一键模式下强制退出, 必须先重启
        log "退出脚本, 请重启后再运行: bash $0 --resume"
        exit 0
    fi

    # ==== Phase 2: 驱动安装 ====
    if [ "$PHASE" = "all" ] || [ "$PHASE" = "2" ]; then
        echo
        log "============================================"
        log "  Phase 2: NVIDIA vGPU 驱动安装"
        log "============================================"
        fetch_driver_patch
        install_rust
        build_vgpu_unlock_rs
        configure_vgpu_unlock
        install_nvidia_driver
        ensure_vgpu_runtime
        verify_driver
        save_state "3"
        [ "$PHASE" = "2" ] && exit 0
    fi

    # ==== Phase 3: 授权服务 ====
    if [ "$PHASE" = "all" ] || [ "$PHASE" = "3" ]; then
        echo
        log "============================================"
        log "  Phase 3: FastAPI-DLS 授权服务"
        log "============================================"
        install_fastapi_dls
        save_state "4"
        [ "$PHASE" = "3" ] && exit 0
    fi

    # ==== Phase 4: vGPU 环境检查 ====
    if [ "$PHASE" = "all" ] || [ "$PHASE" = "4" ]; then
        echo
        log "============================================"
        log "  Phase 4: vGPU 环境检查"
        log "============================================"

        if [ "$ATTACH_VGPU" = "1" ] && [ -n "$VMID" ]; then
            warn "按显式参数 --attach-vgpu 给现有 VM 设置 vGPU"
            configure_vm
        else
            info "主部署脚本只负责空 PVE 主机的 vGPU 环境，不创建/修改任何 VM。"
            info "母机创建请运行: bash pve_create_base_vm.sh"
            info "批量克隆请运行: bash pve_batch_clone.sh"
            info "当前可用 vGPU profile:"
            mdevctl types 2>/dev/null | sed -n '1,120p' || warn "mdevctl types 不可用，请检查驱动和 nvidia-vgpu-mgr 服务"
        fi

        save_state "4"
        [ "$PHASE" = "4" ] && exit 0
    fi

    # ==== Phase 5: 验证报告 ====
    echo
    log "============================================"
    log "  Phase 5: 生成验证报告"
    log "============================================"
    generate_report
    install_self_check || true
    save_state "5"

    # 收尾
    echo
    banner "╔══════════════════════════════════════════════════════════╗"
    banner "║  部署完成!                                              ║"
    banner "╚══════════════════════════════════════════════════════════╝"
    echo
    info "备份目录: ${BACKUP_DIR}"
    info "部署报告: ${REPORT_FILE}"
    info "状态文件: ${STATE_FILE}"
    echo
    warn "后续步骤:"
    warn "  1. 重启 PVE 主机: reboot"
    warn "  2. 验证驱动: nvidia-smi"
    warn "  3. 查看可用 vGPU 类型: mdevctl types"
    warn "  4. 给 VM 分配 vGPU: 在 PVE Web UI → VM → Hardware → Add → PCI Device"
    warn "     选择 GPU, 勾选 'MDEV' 并选择 vGPU 类型"
    warn ""
    warn "  或者用命令: qm set <VMID> --hostpci0 <PCI_ADDR>,pcie=1,mdev=1"
    echo
}

main "$@"

