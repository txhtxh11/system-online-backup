#!/bin/bash
# =============================================================================
# 通用在线系统备份脚本（x86 / ARM / 树莓派 / 飞牛 fnOS / Debian / Ubuntu）
# version: 1.0.0   (2026-10-22)
#
# 思路参考 nanhantianyi/rpi-backup，但做了通用化改造：
#   - 自动识别系统盘、ESP/boot 分区、分区表类型（GPT/MBR）、文件系统
#   - 保留原 UUID 和 PARTUUID → fstab / grub.cfg / cmdline.txt 都不用改
#   - 自动排除数据卷（/vol1、/vol2 等）和虚拟文件系统
#   - 输出最小化镜像（只装已用空间），支持 zstd 压缩
#
# 用法：
#   sudo bash system-online-backup.sh -o /path/backup.img [--zstd] [--dry-run]
#
# 恢复：
#   dd if=backup.img of=/dev/sdX bs=4M status=progress
#   盘更大时：parted /dev/sdX resizepart <root号> 100% && resize2fs /dev/sdXpN
# =============================================================================
set -euo pipefail

IMGFILE=""
USE_ZSTD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) IMGFILE="$2"; shift 2 ;;
        --zstd) USE_ZSTD=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "必须用 root 运行（sudo bash $0 ...）"; exit 1; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "错误: $*" >&2; exit 1; }

# ---- 1. 识别系统盘与分区 -----------------------------------------------------
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" | head -1)
[ -n "$ROOT_DISK" ] || die "无法识别系统盘"
DISK="/dev/$ROOT_DISK"
ROOT_PARTNUM=$(cat "/sys/class/block/$(basename "$ROOT_SRC")/partition")
PTTYPE=$(blkid -o value -s PTTYPE "$DISK" 2>/dev/null || echo unknown)
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_SRC")
ROOT_PARTUUID=$(blkid -o value -s PARTUUID "$ROOT_SRC")
ROOT_LABEL=$(blkid -o value -s LABEL "$ROOT_SRC" 2>/dev/null || true)
DISK_ID=$(sfdisk --disk-id "$DISK" 2>/dev/null || true)

# ESP / boot 分区（三种常见布局）
ESP_SRC=""; ESP_MNT=""; ESP_FSTYPE=""; ESP_UUID=""; ESP_PARTUUID=""; ESP_LABEL=""
for cand in /boot/efi /boot/firmware; do
    if findmnt -no SOURCE "$cand" >/dev/null 2>&1; then
        ESP_SRC=$(findmnt -no SOURCE "$cand"); ESP_MNT="$cand"; break
    fi
done
if [ -z "$ESP_SRC" ] && findmnt -no FSTYPE /boot 2>/dev/null | grep -q vfat; then
    ESP_SRC=$(findmnt -no SOURCE /boot); ESP_MNT="/boot"
fi
if [ -n "$ESP_SRC" ]; then
    ESP_FSTYPE=$(findmnt -no FSTYPE "$ESP_MNT")
    ESP_UUID=$(blkid -o value -s UUID "$ESP_SRC")
    ESP_PARTUUID=$(blkid -o value -s PARTUUID "$ESP_SRC")
    ESP_LABEL=$(blkid -o value -s LABEL "$ESP_SRC" 2>/dev/null || true)
fi

log "系统盘      : $DISK ($PTTYPE)"
log "root        : $ROOT_SRC  $ROOT_FSTYPE  UUID=$ROOT_UUID  PARTUUID=$ROOT_PARTUUID"
if [ -n "$ESP_SRC" ]; then
    log "boot/ESP    : $ESP_SRC -> $ESP_MNT  $ESP_FSTYPE  UUID=$ESP_UUID  PARTUUID=$ESP_PARTUUID"
else
    log "boot/ESP    : 未检测到（BIOS/MBR 启动或 /boot 在 root 上）"
fi

case "$ROOT_FSTYPE" in
    ext2|ext3|ext4|xfs|btrfs|f2fs) ;;
    *) die "暂不支持 root 文件系统: $ROOT_FSTYPE" ;;
esac

# 排除其它挂载点（数据卷 /vol1 /vol2 等）
EXCLUDES=(/proc /sys /dev /run /tmp /mnt /media /lost+found)
while IFS= read -r m; do
    [ -z "$m" ] && continue
    [ "$m" = "/" ] && continue
    case "$m" in
        /proc|/sys|/dev|/run|/tmp|/mnt|/media) ;;
        *) EXCLUDES+=("$m") ;;
    esac
done < <(findmnt -rn -o TARGET)
log "排除挂载点  : ${EXCLUDES[*]}"

# ---- 2. 计算镜像大小 ---------------------------------------------------------
ROOT_USED=$(df -B1 --output=used / | tail -1 | tr -d ' ')
# /swapfile 不备份（恢复后重建），从镜像大小里扣掉，避免镜像虚胖
if [ -f /swapfile ]; then
    SWAP_BYTES=$(stat -c %s /swapfile 2>/dev/null || echo 0)
    ROOT_USED=$(( ROOT_USED - SWAP_BYTES ))
    log "swapfile    : 排除 $(( SWAP_BYTES / 1024 / 1024 ))MB（恢复后需重建）"
fi
ROOT_USED_MB=$(( ROOT_USED / 1024 / 1024 ))
ROOT_SIZE_MB=$(( ROOT_USED_MB * 115 / 100 + 512 ))
ESP_SIZE_MB=0
if [ -n "$ESP_SRC" ]; then
    ESP_USED=$(df -B1 --output=used "$ESP_MNT" | tail -1 | tr -d ' ')
    ESP_USED_MB=$(( ESP_USED / 1024 / 1024 ))
    ESP_SIZE_MB=$(( ESP_USED_MB + 32 ))
    [ "$ESP_SIZE_MB" -lt 64 ] && ESP_SIZE_MB=64
fi
IMG_SIZE_MB=$(( ROOT_SIZE_MB + ESP_SIZE_MB + 4 ))
log "镜像大小    : root ${ROOT_SIZE_MB}MB + ESP ${ESP_SIZE_MB}MB ≈ ${IMG_SIZE_MB}MB"

if [ -z "$IMGFILE" ]; then
    IMGFILE="./backup-$(hostname)-$(date +%Y%m%d-%H%M).img"
fi
OUTDIR=$(dirname "$IMGFILE")
FREE_MB=$(df -B1 --output=avail "$OUTDIR" 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "$FREE_MB" ] && [ $(( FREE_MB / 1024 / 1024 )) -lt "$IMG_SIZE_MB" ]; then
    die "输出目录空间不足：需要 ${IMG_SIZE_MB}MB，可用 $(( FREE_MB / 1024 / 1024 ))MB"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run：只检查，不写文件"
    exit 0
fi

# ---- 3. 创建镜像并分区 -------------------------------------------------------
log "创建镜像 $IMGFILE"
truncate -s "${IMG_SIZE_MB}M" "$IMGFILE"

if [ "$PTTYPE" = "gpt" ]; then
    parted -s "$IMGFILE" mklabel gpt
    if [ "$ESP_SIZE_MB" -gt 0 ]; then
        parted -s "$IMGFILE" mkpart ESP fat32 1MiB "$(( 1 + ESP_SIZE_MB ))MiB"
        parted -s "$IMGFILE" set 1 esp on
        parted -s "$IMGFILE" mkpart root "$ROOT_FSTYPE" "$(( 1 + ESP_SIZE_MB ))MiB" 100%
    else
        parted -s "$IMGFILE" mkpart root "$ROOT_FSTYPE" 1MiB 100%
    fi
else
    parted -s "$IMGFILE" mklabel msdos
    if [ "$ESP_SIZE_MB" -gt 0 ]; then
        parted -s "$IMGFILE" mkpart primary fat32 1MiB "$(( 1 + ESP_SIZE_MB ))MiB"
        parted -s "$IMGFILE" set 1 boot on
        parted -s "$IMGFILE" mkpart primary "$ROOT_FSTYPE" "$(( 1 + ESP_SIZE_MB ))MiB" 100%
    else
        parted -s "$IMGFILE" mkpart primary "$ROOT_FSTYPE" 1MiB 100%
    fi
fi

LOOP=$(losetup -fP --show "$IMGFILE")
log "loop 设备   : $LOOP"
for _ in $(seq 1 20); do
    [ -b "${LOOP}p2" ] && break
    sleep 0.3
done

if [ "$ESP_SIZE_MB" -gt 0 ]; then
    P_ESP="${LOOP}p1"; P_ROOT="${LOOP}p2"
else
    P_ROOT="${LOOP}p1"
fi

cleanup() {
    set +e
    mountpoint -q /mnt/bk-esp 2>/dev/null && umount /mnt/bk-esp
    mountpoint -q /mnt/bk-root 2>/dev/null && umount /mnt/bk-root
    rmdir /mnt/bk-esp /mnt/bk-root 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# ---- 4. 格式化（沿用原 UUID）-------------------------------------------------
if [ "$ESP_SIZE_MB" -gt 0 ]; then
    ESP_SERIAL="${ESP_UUID//-/}"
    log "格式化 ESP  (UUID=$ESP_SERIAL)"
    mkfs.vfat -F 32 -i "$ESP_SERIAL" ${ESP_LABEL:+-n "$ESP_LABEL"} "$P_ESP" >/dev/null
fi

log "格式化 root ($ROOT_FSTYPE, UUID=$ROOT_UUID)"
case "$ROOT_FSTYPE" in
    ext2|ext3|ext4)
        mkfs."$ROOT_FSTYPE" -q -F -U "$ROOT_UUID" ${ROOT_LABEL:+-L "$ROOT_LABEL"} "$P_ROOT" ;;
    xfs)
        mkfs.xfs -q -f -m uuid="$ROOT_UUID" ${ROOT_LABEL:+-L "$ROOT_LABEL"} "$P_ROOT" ;;
    btrfs)
        mkfs.btrfs -q -f -U "$ROOT_UUID" ${ROOT_LABEL:+-L "$ROOT_LABEL"} "$P_ROOT" ;;
    f2fs)
        mkfs.f2fs -q -f -U "$ROOT_UUID" "$P_ROOT" ;;
esac

# ---- 5. 保留 PARTUUID（GPT）或磁盘 ID（MBR），保证 fstab/grub/cmdline 不变 ----
if [ "$PTTYPE" = "gpt" ]; then
    [ -n "$ESP_PARTUUID" ] && [ "$ESP_SIZE_MB" -gt 0 ] && sfdisk --part-uuid "$LOOP" 1 "$ESP_PARTUUID" >/dev/null
    sfdisk --part-uuid "$LOOP" "$([ "$ESP_SIZE_MB" -gt 0 ] && echo 2 || echo 1)" "$ROOT_PARTUUID" >/dev/null
else
    [ -n "$DISK_ID" ] && sfdisk --disk-id "$LOOP" "$DISK_ID" >/dev/null
fi
log "PARTUUID    : 已保留"

# ---- 6. 拷贝数据 -------------------------------------------------------------
mkdir -p /mnt/bk-esp /mnt/bk-root

if [ "$ESP_SIZE_MB" -gt 0 ]; then
    mount "$P_ESP" /mnt/bk-esp
    log "拷贝 ESP ..."
    rsync -aHAX --delete "$ESP_MNT"/ /mnt/bk-esp/
    sync; umount /mnt/bk-esp
fi

mount "$P_ROOT" /mnt/bk-root
log "拷贝 root ...（可能几分钟到几十分钟）"
RSYNC_EXCLUDES=()
for e in "${EXCLUDES[@]}"; do
    [ "$e" = "$ESP_MNT" ] && continue
    RSYNC_EXCLUDES+=("--exclude=$e")
done
[ -f /swapfile ] && RSYNC_EXCLUDES+=("--exclude=/swapfile")
RSYNC_EXCLUDES+=("--exclude=$IMGFILE")   # 防止把镜像自己拷进镜像

rsync -aHAX --numeric-ids --delete "${RSYNC_EXCLUDES[@]}" / /mnt/bk-root/
sync
umount /mnt/bk-root

# ---- 7. 收尾 -----------------------------------------------------------------
e2fsck -f -p "$P_ROOT" >/dev/null 2>&1 || true
losetup -d "$LOOP"
trap - EXIT

log "镜像已生成: $IMGFILE  ($(du -h --apparent-size "$IMGFILE" | cut -f1) 实际 $(du -h "$IMGFILE" | cut -f1))"

if [ "$USE_ZSTD" -eq 1 ]; then
    log "压缩中 ..."
    zstd -T0 -19 --rm "$IMGFILE" -o "${IMGFILE}.zst"
    log "已压缩: ${IMGFILE}.zst"
fi

cat <<EOF

恢复方法：
  # 1) 写盘（注意确认目标盘，写错会丢数据）
  sudo dd if=$(basename "$IMGFILE") of=/dev/sdX bs=4M status=progress conv=fsync

  # 2) 目标盘更大时扩容 root 分区
  sudo parted /dev/sdX resizepart $ROOT_PARTNUM 100%
  sudo partx -u /dev/sdX
  sudo resize2fs /dev/sdXpN        # xfs 用 xfs_growfs，btrfs 用 btrfs filesystem resize max

  # 3) 如果 UEFI 启动项丢失
  sudo efibootmgr -c -d /dev/sdX -p 1 -L "fnOS" -l '\\EFI\\BOOT\\BOOTX64.EFI'
EOF
