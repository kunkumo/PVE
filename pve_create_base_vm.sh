#!/usr/bin/env bash
set -Eeuo pipefail

# 创建单个母机/纯净 VM 脚本
# 运行无参数时会弹出 1/2/3 套餐菜单。
# 套餐会自动设置 CPU / 内存 / 数据盘 / vGPU 显存，并从 mdevctl types 自动选择 PCI + mdev profile。

VMID="${VMID:-100}"
NAME="${NAME:-muji}"
CPU="${CPU:-6}"
MEMORY_MB="${MEMORY_MB:-8192}"
BOOT_DISK_GB="${BOOT_DISK_GB:-60}"
DATA_DISK_GB="${DATA_DISK_GB:-256}"
STORAGE="${STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_MODEL="${NET_MODEL:-e1000}"
MACHINE="${MACHINE:-q35}"
BIOS="${BIOS:-}"
VM_OSTYPE="${VM_OSTYPE:-win11}"
ISO="${ISO:-auto}"
CPU_MODEL_ID="${CPU_MODEL_ID:-Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz}"
DISK0_MODEL="${DISK0_MODEL:-}"
DISK1_MODEL="${DISK1_MODEL:-}"
GPU_PCI="${GPU_PCI:-}"
MDEV_PROFILE="${MDEV_PROFILE:-}"
VGPU_VRAM="${VGPU_VRAM:-1}"
GPU_VENDOR_ID="${GPU_VENDOR_ID:-0x10DE}"
GPU_DEVICE_ID="${GPU_DEVICE_ID:-0x1C31}"
ATTACH_GPU="${ATTACH_GPU:-1}"
DO_TEMPLATE="${DO_TEMPLATE:-0}"
PRESET="${PRESET:-}"
SHOW_MENU=0
ORIG_ARGC="$#"
CLONE_START="101"
CLONE_END="106"
PRESET_NAME="6核/8G/1G/6开"
BIOS_EXPLICIT=0
VRAM_EXPLICIT=0

log(){ echo "[$(date '+%F %T')] $*"; }
err(){ echo "[ERROR] $*" >&2; }

rand_hex(){ local n="$1" out=""; while [ ${#out} -lt "$n" ]; do out="${out}$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"; done; echo "${out:0:$n}"; }
rand_mac(){ printf '02:%s:%s:%s:%s:%s\n' "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)"; }
rand_date(){ printf '%02d/%02d/%04d\n' "$((RANDOM%12+1))" "$((RANDOM%28+1))" "$((2021+RANDOM%4))"; }
pick(){ local arr=("$@"); echo "${arr[$((RANDOM % ${#arr[@]}))]}"; }

pick_disk0_model(){
  pick \
    'Crucial M500 240GB' \
    'Samsung SSD 850 EVO 250GB' \
    'Kingston SA400S37240G' \
    'SanDisk SSD PLUS 240GB' \
    'Silicon Power Ace A55 256GB' \
    'WD Blue SA510 250GB' \
    'Colorful SL500 256GB' \
    'TOSHIBA-TR200 240GB'
}

pick_disk1_model(){
  pick \
    'Adata XPG SX6000 Pro 256GB' \
    'Intel SSD 660p Series 256GB' \
    'Samsung SSD 970 EVO Plus 250GB' \
    'WDC WDS250G2B0C-00PXH0 250GB' \
    'Kingston SNV2S250G 250GB' \
    'Lexar NM620 256GB' \
    'KIOXIA-EXCERIA G2 SSD 250GB' \
    'Netac NV3000 256GB'
}

prepare_disk_models(){
  [ -n "$DISK0_MODEL" ] || DISK0_MODEL="$(pick_disk0_model)"
  if [ "${DATA_DISK_GB:-0}" != "0" ]; then
    [ -n "$DISK1_MODEL" ] || DISK1_MODEL="$(pick_disk1_model)"
  fi
}

build_args(){
  local maker board ver bdate s1 s2 s3 memser asset
  maker="$(pick MSI MAXSUN GIGABYTE ASUS ASRock)"
  board="$(pick 'B460M DS3H' 'B560M DS3H' 'B660M DS3H' 'H610M-K' 'B760M GAMING')"
  ver="VER:H3.7G($(rand_date))"
  bdate="$(rand_date)"
  s1="$(rand_hex 20)"; s2="$(rand_hex 14)"; s3="$(rand_hex 15)"
  memser="$(rand_hex 8)"; asset="$((1000000000 + RANDOM * RANDOM % 8999999999))"
  printf -- '-cpu host,model_id="%s",hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true ' "$CPU_MODEL_ID"
  printf -- '-smbios type=0,vendor="American Megatrends International LLC.",version=H3.7G,date='\''%s'\'',release=3.7 ' "$bdate"
  printf -- '-smbios type=1,manufacturer="%s",product="%s",version="%s",serial="%s",sku="Default string",family="Default string" ' "$maker" "$board" "$ver" "$s1"
  printf -- '-smbios type=2,manufacturer="%s",product="%s",version="%s",serial="%s",asset="Default string",location="Default string" ' "$maker" "$board" "$ver" "$s2"
  printf -- '-smbios type=3,manufacturer="Default string",version="Default string",serial="%s",asset="Default string",sku="Default string" ' "$s3"
  printf -- '-smbios type=17,serial=%s,asset="%s" ' "$memser" "$asset"
  printf -- '-smbios type=4,manufacturer="Intel(R) Corporation",version="%s" -smbios type=9 -smbios type=8 -smbios type=8' "$CPU_MODEL_ID"
  [ -n "$DISK0_MODEL" ] && printf -- ' -set device.sata0.model="%s"' "$DISK0_MODEL"
  [ "${DATA_DISK_GB:-0}" != "0" ] && [ -n "$DISK1_MODEL" ] && printf -- ' -set device.sata1.model="%s"' "$DISK1_MODEL"
}

vram_to_mb(){
  local v="${1,,}"; v="${v// /}"
  if [[ "$v" =~ ^([0-9]+)(g|gb|gib)$ ]]; then echo "$((${BASH_REMATCH[1]} * 1024))"
  elif [[ "$v" =~ ^([0-9]+)(m|mb|mib)$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^([0-9]+)\.([0-9]+)(g|gb|gib)$ ]]; then awk -v n="$v" 'BEGIN{printf "%d", n*1024}'
  elif [[ "$v" =~ ^[0-9]+$ ]]; then [ "$v" -le 64 ] && echo "$((v * 1024))" || echo "$v"
  else err "显存参数格式错误: $1，示例: --vram 1 / --vram 1.2 / --vram 1200M"; exit 1
  fi
}

try_mdev_candidate(){
  [ -n "${cur_pci:-}" ] && [ -n "${cur_profile:-}" ] && [ -n "${cur_fb:-}" ] || return 0
  [ "${cur_avail:-0}" -gt 0 ] || return 0
  [ -z "$GPU_PCI" ] || [ "$cur_pci" = "$GPU_PCI" ] || return 0
  local diff
  if [ "$cur_fb" -ge "$want_mb" ]; then diff=$((cur_fb - want_mb)); else diff=$((999999 + want_mb - cur_fb)); fi
  if [ "$diff" -lt "$best_diff" ]; then
    best_diff="$diff"; best_pci="$cur_pci"; best_profile="$cur_profile"; best_fb="$cur_fb"
  fi
}

resolve_iso(){
  local x="${ISO,,}" storage volid label p already i choice

  case "$x" in
    none|no|0|false) ISO=""; log "按 --iso none 跳过 ISO 挂载"; return 0 ;;
  esac

  # 用户明确指定了 ISO → 直接用
  if [ -n "$ISO" ] && [ "$x" != "auto" ]; then
    log "使用指定 ISO: $ISO"
    return 0
  fi

  ISO=""
  local -a iso_list=()
  local -a iso_labels=()

  # 从 PVE 存储收集 ISO
  if command -v pvesm >/dev/null 2>&1; then
    for storage in $(pvesm status 2>/dev/null | awk 'NR>1{print $1}'); do
      while IFS= read -r volid; do
        [[ "$volid" =~ :iso/ ]] || continue
        already=0
        for e in "${iso_list[@]}"; do [ "$e" = "$volid" ] && already=1 && break; done
        [ "$already" = "1" ] && continue
        iso_list+=("$volid")
        iso_labels+=("${volid#*:iso/}")
      done < <(pvesm list "$storage" --content iso 2>/dev/null | awk 'NR>1{print $1}')
    done
  fi

  # 文件系统兜底
  for p in /var/lib/vz/template/iso/*.iso /var/lib/vz/template/iso/*.ISO; do
    [ -f "$p" ] || continue
    volid="local:iso/$(basename "$p")"
    already=0
    for e in "${iso_list[@]}"; do [ "$e" = "$volid" ] && already=1 && break; done
    [ "$already" = "1" ] && continue
    iso_list+=("$volid")
    iso_labels+=("$(basename "$p")")
  done

  if [ ${#iso_list[@]} -eq 0 ]; then
    log "没有找到任何 ISO，跳过光驱挂载"
    return 0
  fi

  # 交互式终端 → 显示菜单让用户选
  if [ -t 0 ]; then
    echo
    echo "════════════ 可用的 ISO 镜像 ════════════"
    echo "  0) 跳过，不挂载 ISO"
    i=1
    for label in "${iso_labels[@]}"; do
      echo "  $i) $label"
      ((i++))
    done
    echo "══════════════════════════════════════════"
    echo
    while true; do
      read -rp "请选择 ISO 编号 [0-${#iso_list[@]}]: " choice
      if [ "$choice" = "0" ]; then
        ISO=""
        log "已跳过 ISO 挂载"
        return 0
      elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#iso_list[@]}" ]; then
        ISO="${iso_list[$((choice - 1))]}"
        log "已选择 ISO: ${iso_labels[$((choice - 1))]}"
        return 0
      else
        echo "  → 无效选择，请输入 0-${#iso_list[@]}"
      fi
    done
  fi

  # 非交互 → 自动选第一个
  ISO="${iso_list[0]}"
  log "自动使用 ISO: ${iso_labels[0]}"
}

resolve_vgpu_profile(){
  if [ -n "$MDEV_PROFILE" ]; then
    mdevctl types 2>/dev/null | grep -q "$MDEV_PROFILE" || { err "没有检测到 mdev profile: $MDEV_PROFILE"; exit 1; }
    [ -n "$GPU_PCI" ] || GPU_PCI="$(mdevctl types 2>/dev/null | awk 'p&&/^0000:/{exit} /^0000:/{pci=$1} $1==p{print pci; exit}' p="$MDEV_PROFILE")"
    log "使用指定 vGPU profile: ${GPU_PCI},mdev=${MDEV_PROFILE}"
    return 0
  fi
  want_mb="$(vram_to_mb "$VGPU_VRAM")"
  best_diff=999999999; best_pci=""; best_profile=""; best_fb=""
  cur_pci=""; cur_profile=""; cur_fb=""; cur_avail=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9a-fA-F]{4}: ]]; then cur_pci="${line%% *}"; continue; fi
    if [[ "$line" =~ ^[[:space:]]+(nvidia-[0-9]+) ]]; then cur_profile="${BASH_REMATCH[1]}"; cur_fb=""; cur_avail=0; continue; fi
    if [[ "$line" =~ Available[[:space:]]instances:[[:space:]]*([0-9]+) ]]; then cur_avail="${BASH_REMATCH[1]}"; try_mdev_candidate; fi
    if [[ "$line" =~ framebuffer=([0-9]+)([MG]) ]]; then cur_fb="${BASH_REMATCH[1]}"; [ "${BASH_REMATCH[2]}" = "G" ] && cur_fb="$((cur_fb * 1024))"; try_mdev_candidate; fi
  done < <(mdevctl types 2>/dev/null)
  [ -n "$best_profile" ] || { err "找不到可用的 ${VGPU_VRAM} 显存 vGPU profile；请先运行 mdevctl types 查看"; exit 1; }
  GPU_PCI="$best_pci"; MDEV_PROFILE="$best_profile"
  log "自动选择 vGPU: ${GPU_PCI},mdev=${MDEV_PROFILE}, framebuffer=${best_fb}M, 需求=${want_mb}M"
}

apply_preset(){
  case "${1,,}" in
    1|a)
      PRESET_NAME="6核 / 8G内存 / 256G硬盘 / 1G显存 / 克隆101-106"
      CPU=6; MEMORY_MB=8192; DATA_DISK_GB=256; VGPU_VRAM=1; CLONE_START=101; CLONE_END=106 ;;
    2|b)
      PRESET_NAME="8核 / 12G内存 / 256G硬盘 / 1.2G显存 / 克隆101-105"
      CPU=8; MEMORY_MB=12288; DATA_DISK_GB=256; VGPU_VRAM=1200M; CLONE_START=101; CLONE_END=105 ;;
    3|c)
      PRESET_NAME="12核 / 16G内存 / 256G硬盘 / 2G显存 / 克隆101-103"
      CPU=12; MEMORY_MB=16384; DATA_DISK_GB=256; VGPU_VRAM=2; CLONE_START=101; CLONE_END=103 ;;
    *) err "无效套餐: $1，只能选 1/2/3 或 A/B/C"; exit 1 ;;
  esac
  MDEV_PROFILE="${MDEV_PROFILE:-}"
  log "已选择套餐: $PRESET_NAME"
}

select_preset_interactive(){
  {
    echo
    echo "请选择母机/克隆规格："
    echo "  1 / A) CPU 6核  | 硬盘 256G | 内存 8G  | 显存 1G   | 克隆 101-106 共6台"
    echo "  2 / B) CPU 8核  | 硬盘 256G | 内存 12G | 显存 1.2G | 克隆 101-105 共5台"
    echo "  3 / C) CPU 12核 | 硬盘 256G | 内存 16G | 显存 2G   | 克隆 101-103 共3台"
    echo
  } > /dev/tty 2>/dev/null || {
    echo
    echo "请选择母机/克隆规格："
    echo "  1 / A) CPU 6核  | 硬盘 256G | 内存 8G  | 显存 1G   | 克隆 101-106 共6台"
    echo "  2 / B) CPU 8核  | 硬盘 256G | 内存 12G | 显存 1.2G | 克隆 101-105 共5台"
    echo "  3 / C) CPU 12核 | 硬盘 256G | 内存 16G | 显存 2G   | 克隆 101-103 共3台"
    echo
  }
  PRESET="$(ask_tty "请输入 1/2/3 或 A/B/C: ")"
  apply_preset "$PRESET"
}

ask_tty(){
  local prompt="$1" answer=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || true
  elif [ -t 0 ]; then
    read -rp "$prompt" answer || true
  fi
  echo "$answer"
}

select_bios_interactive(){
  local choice
  echo > /dev/tty 2>/dev/null || true
  {
    echo "请选择母机 BIOS 启动方式："
    echo "  1) OVMF / UEFI  推荐：Win11、现代系统、直通兼容性更好"
    echo "  2) SeaBIOS      传统 BIOS：兼容旧系统/旧工具"
    echo
  } > /dev/tty 2>/dev/null || {
    echo
    echo "请选择母机 BIOS 启动方式："
    echo "  1) OVMF / UEFI  推荐：Win11、现代系统、直通兼容性更好"
    echo "  2) SeaBIOS      传统 BIOS：兼容旧系统/旧工具"
    echo
  }

  while true; do
    choice="$(ask_tty "请输入 1/2，直接回车默认 1(OVMF): ")"
    case "${choice:-1}" in
      1|ovmf|OVMF|uefi|UEFI)
        BIOS="ovmf"
        MACHINE="${MACHINE:-q35}"
        log "已选择 BIOS: OVMF / UEFI"
        return 0
        ;;
      2|sea|Sea|seabios|SeaBIOS|legacy|Legacy)
        BIOS="seabios"
        MACHINE="${MACHINE:-q35}"
        log "已选择 BIOS: SeaBIOS"
        return 0
        ;;
      *)
        echo "  → 无效选择，请输入 1 或 2" > /dev/tty 2>/dev/null || echo "  → 无效选择，请输入 1 或 2"
        ;;
    esac
  done
}

normalize_bios(){
  case "${BIOS,,}" in
    ovmf|uefi) BIOS="ovmf" ;;
    sea|seabios|legacy) BIOS="seabios" ;;
    "") BIOS="seabios" ;;
    *) err "无效 BIOS: $BIOS，只能用 ovmf/uefi 或 seabios/sea"; exit 1 ;;
  esac
}

select_vram_interactive(){
  local choice custom
  {
    echo
    echo "请选择 vGPU 显存大小："
    echo "  1) 1G    适合 6开/轻量使用"
    echo "  2) 1.2G  适合 5开/稍高显存需求"
    echo "  3) 2G    适合 3开/较高显存需求"
    echo "  4) 自定义，例如 512M、1、1200M、2G"
    echo
  } > /dev/tty 2>/dev/null || {
    echo
    echo "请选择 vGPU 显存大小："
    echo "  1) 1G    适合 6开/轻量使用"
    echo "  2) 1.2G  适合 5开/稍高显存需求"
    echo "  3) 2G    适合 3开/较高显存需求"
    echo "  4) 自定义，例如 512M、1、1200M、2G"
    echo
  }

  while true; do
    choice="$(ask_tty "请输入 1/2/3/4，直接回车使用套餐默认 ${VGPU_VRAM}: ")"
    case "${choice:-default}" in
      default|"")
        log "使用套餐默认 vGPU 显存: ${VGPU_VRAM}"
        return 0
        ;;
      1)
        VGPU_VRAM=1
        log "已选择 vGPU 显存: 1G"
        return 0
        ;;
      2)
        VGPU_VRAM=1200M
        log "已选择 vGPU 显存: 1.2G"
        return 0
        ;;
      3)
        VGPU_VRAM=2
        log "已选择 vGPU 显存: 2G"
        return 0
        ;;
      4|custom|Custom)
        custom="$(ask_tty "请输入自定义显存，例如 512M、1、1200M、2G: ")"
        if [ -n "$custom" ]; then
          vram_to_mb "$custom" >/dev/null
          VGPU_VRAM="$custom"
          log "已选择自定义 vGPU 显存: ${VGPU_VRAM}"
          return 0
        fi
        ;;
      *)
        if vram_to_mb "$choice" >/dev/null 2>&1; then
          VGPU_VRAM="$choice"
          log "已选择自定义 vGPU 显存: ${VGPU_VRAM}"
          return 0
        fi
        echo "  → 无效选择，请输入 1/2/3/4 或显存值" > /dev/tty 2>/dev/null || echo "  → 无效选择，请输入 1/2/3/4 或显存值"
        ;;
    esac
  done
}

usage(){
cat <<'EOF'
用法：
  bash pve_create_base_vm.sh
  bash pve_create_base_vm.sh --preset 1 --vmid 100 --name muji

套餐：
  1/A  CPU 6核  / 内存 8G  / 数据盘 256G / vGPU 1G   / 克隆 101-106
  2/B  CPU 8核  / 内存 12G / 数据盘 256G / vGPU 1.2G / 克隆 101-105
  3/C  CPU 12核 / 内存 16G / 数据盘 256G / vGPU 2G   / 克隆 101-103

参数：
  --preset 1|2|3|A|B|C  直接选择套餐，不弹菜单
  --vmid ID             母机 VMID，默认 100
  --name NAME           母机名称，默认 muji
  --cpu N               手动覆盖 CPU 核数
  --mem MB              手动覆盖内存 MB
  --boot-disk GB        第一块系统盘 sata0，默认 60G
  --data-disk GB        第二块数据盘 sata1，默认 256G
  --storage NAME        PVE 存储，默认 local
  --gpu PCI             指定 NVIDIA GPU PCI；不填则自动选择
  --vram 1|1200M|2G     指定 vGPU 显存；不指定且可交互时会询问
  --gpu-vendor-id HEX   vGPU PCI 供应商 ID，默认 0x10DE
  --gpu-device-id HEX   vGPU PCI 设备 ID，默认 0x1C31 (Quadro P2200)
  --bios ovmf|seabios   指定 BIOS；不指定且可交互时会询问
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --preset|--plan) PRESET="$2"; shift 2;;
    --menu) SHOW_MENU=1; shift;;
    --vmid) VMID="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --cpu) CPU="$2"; shift 2;;
    --mem) MEMORY_MB="$2"; shift 2;;
    --boot-disk) BOOT_DISK_GB="$2"; shift 2;;
    --data-disk|--disk) DATA_DISK_GB="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --gpu) GPU_PCI="$2"; shift 2;;
    --mdev) MDEV_PROFILE="$2"; shift 2;;
    --vram|--vram-gb) VGPU_VRAM="$2"; VRAM_EXPLICIT=1; shift 2;;
    --gpu-vendor-id) GPU_VENDOR_ID="$2"; shift 2;;
    --gpu-device-id) GPU_DEVICE_ID="$2"; shift 2;;
    --no-gpu) ATTACH_GPU=0; shift;;
    --attach-gpu) ATTACH_GPU=1; shift;;
    --bridge) BRIDGE="$2"; shift 2;;
    --net) NET_MODEL="$2"; shift 2;;
    --machine) MACHINE="$2"; shift 2;;
    --bios) BIOS="$2"; BIOS_EXPLICIT=1; shift 2;;
    --ostype) VM_OSTYPE="$2"; shift 2;;
    --iso) ISO="$2"; shift 2;;
    --cpu-model) CPU_MODEL_ID="$2"; shift 2;;
    --disk0-model) DISK0_MODEL="$2"; shift 2;;
    --disk1-model) DISK1_MODEL="$2"; shift 2;;
    --template) DO_TEMPLATE=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "未知参数: $1"; usage; exit 1;;
  esac
done

if [ -n "$PRESET" ]; then
  apply_preset "$PRESET"
elif { [ "$ORIG_ARGC" = "0" ] || [ "$SHOW_MENU" = "1" ]; } && { [ -t 0 ] || [ -r /dev/tty ]; }; then
  select_preset_interactive
fi

if [ "$BIOS_EXPLICIT" = "0" ] && { [ "$ORIG_ARGC" = "0" ] || [ "$SHOW_MENU" = "1" ]; } && { [ -t 0 ] || [ -r /dev/tty ]; }; then
  select_bios_interactive
else
  normalize_bios
fi

if [ "$VRAM_EXPLICIT" = "0" ] && [ "$ATTACH_GPU" = "1" ] && { [ "$ORIG_ARGC" = "0" ] || [ "$SHOW_MENU" = "1" ]; } && { [ -t 0 ] || [ -r /dev/tty ]; }; then
  select_vram_interactive
else
  vram_to_mb "$VGPU_VRAM" >/dev/null
fi

[ "${EUID}" -eq 0 ] || { err "请用 root 执行"; exit 1; }
command -v qm >/dev/null || { err "未找到 qm，请在 PVE 宿主机执行"; exit 1; }
if qm status "$VMID" >/dev/null 2>&1; then err "VMID $VMID 已存在"; exit 1; fi

grep -q "114.114.114.114" /etc/resolv.conf 2>/dev/null || printf "nameserver 114.114.114.114\nnameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf
resolve_iso
prepare_disk_models

log "创建母机 VMID=$VMID NAME=$NAME CPU=$CPU MEM=${MEMORY_MB}MB BOOT=${BOOT_DISK_GB}G DATA=${DATA_DISK_GB}G BIOS=${BIOS} MACHINE=${MACHINE} vGPU=${VGPU_VRAM}"
log "硬盘伪装: sata0=${DISK0_MODEL}${DISK1_MODEL:+ / sata1=${DISK1_MODEL}}"
qm create "$VMID" --name "$NAME" --memory "$MEMORY_MB" --balloon 0 --sockets 1 --cores "$CPU" --cpu host \
  --bios "$BIOS" --machine "$MACHINE" --vga std --numa 0 --ostype "$VM_OSTYPE" \
  --scsihw virtio-scsi-single --net0 "${NET_MODEL}=$(rand_mac),bridge=${BRIDGE},firewall=1" \
  --audio0 device=ich9-intel-hda,driver=none

if [ "$BIOS" = "ovmf" ]; then
  qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
fi

qm set "$VMID" --args "$(build_args)"
if [ "$ATTACH_GPU" = "1" ]; then
  resolve_vgpu_profile
  HOSTPCI0_OPTS="${GPU_PCI},mdev=${MDEV_PROFILE},pcie=1"
  if [ -n "$GPU_VENDOR_ID" ] && [ -n "$GPU_DEVICE_ID" ]; then
    HOSTPCI0_OPTS="${HOSTPCI0_OPTS},vendor-id=${GPU_VENDOR_ID},device-id=${GPU_DEVICE_ID}"
    log "vGPU PCI ID 伪装: vendor-id=${GPU_VENDOR_ID}, device-id=${GPU_DEVICE_ID}"
  fi
  qm set "$VMID" --hostpci0 "$HOSTPCI0_OPTS"
  qm set "$VMID" --vga std
else
  log "按 --no-gpu 跳过 vGPU 挂载"
fi
qm set "$VMID" --sata0 "${STORAGE}:${BOOT_DISK_GB},discard=on,serial=$(rand_hex 20),ssd=1"
if [ "${DATA_DISK_GB:-0}" != "0" ]; then
  qm set "$VMID" --sata1 "${STORAGE}:${DATA_DISK_GB},discard=on,serial=$(rand_hex 20),ssd=1"
else
  log "DATA_DISK_GB=0，跳过第二块数据盘 sata1"
fi
qm set "$VMID" --agent 1

if [ -n "$ISO" ]; then
  qm set "$VMID" --ide2 "${ISO},media=cdrom"
  # ISO 只作为安装盘挂着，启动顺序保持硬盘 sata0 第一。
  # 空盘首次会自动落到 ISO；安装后重启会优先从硬盘启动，避免重复进安装程序。
  qm set "$VMID" --boot order=sata0\;ide2
else
  qm set "$VMID" --boot order=sata0
fi
[ "$DO_TEMPLATE" = "1" ] && qm template "$VMID"

cat > "/root/.pve_vgpu_last_preset" <<EOF
SRC_VMID=$VMID
START_ID=$CLONE_START
END_ID=$CLONE_END
CPU=$CPU
MEMORY_MB=$MEMORY_MB
VGPU_VRAM=$VGPU_VRAM
GPU_PCI=$GPU_PCI
MDEV_PROFILE=$MDEV_PROFILE
NAME_PREFIX=A1
BIOS=$BIOS
MACHINE=$MACHINE
EOF

log "完成：母机已按套餐生成，并写入随机 args / SMBIOS / serial / MAC。"
log ""
log "⚠ 下一步：启动母机装好 Windows 后，关机执行以下命令去掉 ISO："
log "    qm set ${VMID} --delete ide2"
log "    qm set ${VMID} --boot order=sata0"
log ""
log "装好系统去掉 ISO 后再克隆："
log "    bash pve_batch_clone.sh --src ${VMID} --start ${CLONE_START} --end ${CLONE_END} --prefix A1 --vram ${VGPU_VRAM}"
