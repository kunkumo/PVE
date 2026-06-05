#!/usr/bin/env bash
set -Eeuo pipefail

# 批量克隆全自动脚本
# 无参数运行时同样弹出 1/2/3 套餐菜单。
# 会按套餐设置 CPU / 内存 / 克隆范围 / vGPU 显存，并自动选择 PCI + mdev profile。

SRC_VMID="${SRC_VMID:-100}"
START_ID="${START_ID:-101}"
END_ID="${END_ID:-106}"
NAME_PREFIX="${NAME_PREFIX:-A1}"
WALLPAPER_NO="${WALLPAPER_NO:-1}"
FULL_CLONE="${FULL_CLONE:-0}"
TARGET_STORAGE="${TARGET_STORAGE:-}"
CPU="${CPU:-6}"
MEMORY_MB="${MEMORY_MB:-8192}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_MODEL="${NET_MODEL:-e1000}"
GPU_PCI="${GPU_PCI:-}"
MDEV_PROFILE="${MDEV_PROFILE:-}"
VGPU_VRAM="${VGPU_VRAM:-1}"
CPU_MODEL_ID="${CPU_MODEL_ID:-Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz}"
DISK0_MODEL="${DISK0_MODEL:-}"
DISK1_MODEL="${DISK1_MODEL:-}"
USER_DISK0_MODEL="$DISK0_MODEL"
USER_DISK1_MODEL="$DISK1_MODEL"
HAS_SATA1=1
START_AFTER="${START_AFTER:-0}"
PRESET="${PRESET:-}"
SHOW_MENU=0
ORIG_ARGC="$#"

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

randomize_disk_models(){
  DISK0_MODEL="${USER_DISK0_MODEL:-$(pick_disk0_model)}"
  DISK1_MODEL="${USER_DISK1_MODEL:-$(pick_disk1_model)}"
}

build_args(){
  local maker board ver bdate s1 s2 s3 memser asset
  maker="$(pick MSI MAXSUN GIGABYTE ASUS ASRock)"
  board="$(pick 'B460M DS3H' 'B560M DS3H' 'B660M DS3H' 'H610M-K' 'B760M GAMING')"
  ver="VER:H3.7G($(rand_date))"; bdate="$(rand_date)"
  s1="$(rand_hex 20)"; s2="$(rand_hex 14)"; s3="$(rand_hex 15)"; memser="$(rand_hex 8)"
  asset="$((1000000000 + RANDOM * RANDOM % 8999999999))"
  printf -- '-cpu host,model_id="%s",hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true ' "$CPU_MODEL_ID"
  printf -- '-smbios type=0,vendor="American Megatrends International LLC.",version=H3.7G,date='\''%s'\'',release=3.7 ' "$bdate"
  printf -- '-smbios type=1,manufacturer="%s",product="%s",version="%s",serial="%s",sku="Default string",family="Default string" ' "$maker" "$board" "$ver" "$s1"
  printf -- '-smbios type=2,manufacturer="%s",product="%s",version="%s",serial="%s",asset="Default string",location="Default string" ' "$maker" "$board" "$ver" "$s2"
  printf -- '-smbios type=3,manufacturer="Default string",version="Default string",serial="%s",asset="Default string",sku="Default string" ' "$s3"
  printf -- '-smbios type=17,serial=%s,asset="%s" ' "$memser" "$asset"
  printf -- '-smbios type=4,manufacturer="Intel(R) Corporation",version="%s" -smbios type=9 -smbios type=8 -smbios type=8' "$CPU_MODEL_ID"
  [ -n "$DISK0_MODEL" ] && printf -- ' -set device.sata0.model="%s"' "$DISK0_MODEL"
  [ "${HAS_SATA1:-1}" = "1" ] && [ -n "$DISK1_MODEL" ] && printf -- ' -set device.sata1.model="%s"' "$DISK1_MODEL"
}

vram_to_mb(){
  local v="${1,,}"; v="${v// /}"
  if [[ "$v" =~ ^([0-9]+)(g|gb|gib)$ ]]; then echo "$((${BASH_REMATCH[1]} * 1024))"
  elif [[ "$v" =~ ^([0-9]+)(m|mb|mib)$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^([0-9]+)\.([0-9]+)(g|gb|gib)$ ]]; then awk -v n="$v" 'BEGIN{printf "%d", n*1024}'
  elif [[ "$v" =~ ^[0-9]+$ ]]; then [ "$v" -le 64 ] && echo "$((v * 1024))" || echo "$v"
  else err "显存参数格式错误: $1"; exit 1
  fi
}
try_mdev_candidate(){
  [ -n "${cur_pci:-}" ] && [ -n "${cur_profile:-}" ] && [ -n "${cur_fb:-}" ] || return 0
  [ "${cur_avail:-0}" -gt 0 ] || return 0
  [ -z "$GPU_PCI" ] || [ "$cur_pci" = "$GPU_PCI" ] || return 0
  local diff; if [ "$cur_fb" -ge "$want_mb" ]; then diff=$((cur_fb - want_mb)); else diff=$((999999 + want_mb - cur_fb)); fi
  if [ "$diff" -lt "$best_diff" ]; then best_diff="$diff"; best_pci="$cur_pci"; best_profile="$cur_profile"; best_fb="$cur_fb"; fi
}
resolve_vgpu_profile(){
  if [ -n "$MDEV_PROFILE" ]; then
    mdevctl types 2>/dev/null | grep -q "$MDEV_PROFILE" || { err "没有检测到 mdev profile: $MDEV_PROFILE"; exit 1; }
    [ -n "$GPU_PCI" ] || GPU_PCI="$(mdevctl types 2>/dev/null | awk 'p&&/^0000:/{exit} /^0000:/{pci=$1} $1==p{print pci; exit}' p="$MDEV_PROFILE")"
    return 0
  fi
  want_mb="$(vram_to_mb "$VGPU_VRAM")"; best_diff=999999999; best_pci=""; best_profile=""; best_fb=""
  cur_pci=""; cur_profile=""; cur_fb=""; cur_avail=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9a-fA-F]{4}: ]]; then cur_pci="${line%% *}"; continue; fi
    if [[ "$line" =~ ^[[:space:]]+(nvidia-[0-9]+) ]]; then cur_profile="${BASH_REMATCH[1]}"; cur_fb=""; cur_avail=0; continue; fi
    if [[ "$line" =~ Available[[:space:]]instances:[[:space:]]*([0-9]+) ]]; then cur_avail="${BASH_REMATCH[1]}"; try_mdev_candidate; fi
    if [[ "$line" =~ framebuffer=([0-9]+)([MG]) ]]; then cur_fb="${BASH_REMATCH[1]}"; [ "${BASH_REMATCH[2]}" = "G" ] && cur_fb="$((cur_fb * 1024))"; try_mdev_candidate; fi
  done < <(mdevctl types 2>/dev/null)
  [ -n "$best_profile" ] || { err "找不到可用的 ${VGPU_VRAM} 显存 vGPU profile"; exit 1; }
  GPU_PCI="$best_pci"; MDEV_PROFILE="$best_profile"
  log "自动选择 vGPU: ${GPU_PCI},mdev=${MDEV_PROFILE}, framebuffer=${best_fb}M"
}

apply_preset(){
  case "${1,,}" in
    1|a) CPU=6; MEMORY_MB=8192; VGPU_VRAM=1; START_ID=101; END_ID=106; PRESET_NAME="6核/8G/1G/6开" ;;
    2|b) CPU=8; MEMORY_MB=12288; VGPU_VRAM=1200M; START_ID=101; END_ID=105; PRESET_NAME="8核/12G/1.2G/5开" ;;
    3|c) CPU=12; MEMORY_MB=16384; VGPU_VRAM=2; START_ID=101; END_ID=103; PRESET_NAME="12核/16G/2G/3开" ;;
    *) err "无效套餐: $1，只能选 1/2/3 或 A/B/C"; exit 1 ;;
  esac
  log "已选择套餐: $PRESET_NAME"
}
select_preset_interactive(){
  echo
  echo "请选择克隆规格："
  echo "  1 / A) CPU 6核  | 硬盘 256G | 内存 8G  | 显存 1G   | 克隆 101-106 共6台"
  echo "  2 / B) CPU 8核  | 硬盘 256G | 内存 12G | 显存 1.2G | 克隆 101-105 共5台"
  echo "  3 / C) CPU 12核 | 硬盘 256G | 内存 16G | 显存 2G   | 克隆 101-103 共3台"
  echo
  if [ -r /dev/tty ]; then
    read -rp "请输入 1/2/3 或 A/B/C: " PRESET < /dev/tty
  else
    read -rp "请输入 1/2/3 或 A/B/C: " PRESET
  fi
  apply_preset "$PRESET"
}

usage(){
cat <<'EOF'
用法：
  bash pve_batch_clone.sh
  bash pve_batch_clone.sh --preset 1 --src 100 --prefix A1

克隆模式：
  默认使用链接克隆：--full 0，速度快、省空间，但母机必须先转模板。
  如需完整克隆，加参数：--full-clone
  如需强制链接克隆，加参数：--linked-clone
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --preset|--plan) PRESET="$2"; shift 2;;
    --menu) SHOW_MENU=1; shift;;
    --src) SRC_VMID="$2"; shift 2;;
    --start) START_ID="$2"; shift 2;;
    --end) END_ID="$2"; shift 2;;
    --prefix) NAME_PREFIX="$2"; shift 2;;
    --wall) WALLPAPER_NO="$2"; shift 2;;
    --storage) TARGET_STORAGE="$2"; shift 2;;
    --full-clone) FULL_CLONE=1; shift;;
    --linked-clone) FULL_CLONE=0; shift;;
    --cpu) CPU="$2"; shift 2;;
    --mem) MEMORY_MB="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --net) NET_MODEL="$2"; shift 2;;
    --gpu) GPU_PCI="$2"; shift 2;;
    --mdev) MDEV_PROFILE="$2"; shift 2;;
    --vram|--vram-gb) VGPU_VRAM="$2"; shift 2;;
    --cpu-model) CPU_MODEL_ID="$2"; shift 2;;
    --disk0-model) USER_DISK0_MODEL="$2"; shift 2;;
    --disk1-model) USER_DISK1_MODEL="$2"; shift 2;;
    --start-after) START_AFTER=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "未知参数: $1"; usage; exit 1;;
  esac
done

if [ "$ORIG_ARGC" = "0" ] && [ -f /root/.pve_vgpu_last_preset ]; then
  . /root/.pve_vgpu_last_preset
fi

if [ -n "$PRESET" ]; then
  apply_preset "$PRESET"
elif { [ "$ORIG_ARGC" = "0" ] || [ "$SHOW_MENU" = "1" ]; } && { [ -t 0 ] || [ -r /dev/tty ]; }; then
  select_preset_interactive
fi

[ "${EUID}" -eq 0 ] || { err "请用 root 执行"; exit 1; }
command -v qm >/dev/null || { err "未找到 qm，请在 PVE 宿主机执行"; exit 1; }
qm status "$SRC_VMID" >/dev/null || { err "母机/模板 VMID $SRC_VMID 不存在"; exit 1; }

if [ "$FULL_CLONE" = "0" ]; then
  if ! qm config "$SRC_VMID" | grep -q '^template: 1'; then
    err "链接克隆要求来源 VMID $SRC_VMID 已经是模板。"
    err "请先确认母机已关机，然后执行: qm template $SRC_VMID"
    err "如果你不想转模板，请改用完整克隆参数: --full-clone"
    exit 1
  fi
  log "克隆模式: 链接克隆 linked clone (--full 0)，速度快、省空间"
else
  log "克隆模式: 完整克隆 full clone (--full 1)，速度慢、占空间大"
fi

grep -q "114.114.114.114" /etc/resolv.conf 2>/dev/null || printf "nameserver 114.114.114.114\nnameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf
resolve_vgpu_profile

for id in $(seq "$START_ID" "$END_ID"); do
  if qm status "$id" >/dev/null 2>&1; then err "VMID $id 已存在，跳过"; continue; fi
  index=$((id - START_ID + 1))
  name="${NAME_PREFIX}-${index}"
  log "克隆 $SRC_VMID -> $id ($name)"
  args=(clone "$SRC_VMID" "$id" --full "$FULL_CLONE" --name "$name")
  [ -n "$TARGET_STORAGE" ] && args+=(--storage "$TARGET_STORAGE")
  qm "${args[@]}"

  sata0_vol="$(qm config "$id" | sed -n 's/^sata0: //p' | cut -d, -f1)"
  sata1_vol="$(qm config "$id" | sed -n 's/^sata1: //p' | cut -d, -f1)"
  [ -n "$sata1_vol" ] && HAS_SATA1=1 || HAS_SATA1=0
  randomize_disk_models
  log "硬盘伪装 $id: sata0=${DISK0_MODEL}${sata1_vol:+ / sata1=${DISK1_MODEL}}"
  qm set "$id" --memory "$MEMORY_MB" --balloon 0 --sockets 1 --cores "$CPU" --cpu host
  qm set "$id" --bios seabios --machine q35 --vga std --numa 0 --ostype win11
  qm set "$id" --scsihw virtio-scsi-single --agent 1
  qm set "$id" --args "$(build_args)"
  qm set "$id" --net0 "${NET_MODEL}=$(rand_mac),bridge=${BRIDGE},firewall=1"
  qm set "$id" --audio0 device=ich9-intel-hda,driver=none
  [ -n "$sata0_vol" ] && qm set "$id" --sata0 "${sata0_vol},discard=on,serial=$(rand_hex 20),ssd=1"
  [ -n "$sata1_vol" ] && qm set "$id" --sata1 "${sata1_vol},discard=on,serial=$(rand_hex 20),ssd=1"
  qm set "$id" --hostpci0 "${GPU_PCI},mdev=${MDEV_PROFILE},pcie=1"
  qm set "$id" --vga std
  if qm config "$id" | grep -q '^ide2:'; then
    qm set "$id" --boot order=sata0\;ide2
  else
    qm set "$id" --boot order=sata0
  fi
  qm set "$id" --description "批量克隆: 母机=${SRC_VMID}; 名称=${name}; 壁纸序号=${WALLPAPER_NO}; mdev=${MDEV_PROFILE}; vram=${VGPU_VRAM}"
  [ "$START_AFTER" = "1" ] && qm start "$id" || true
done

log "批量克隆完成：${START_ID}-${END_ID}"
