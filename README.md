# system-online-backup

> 在**运行中**的 Linux 上，把系统盘（ESP + root）做成一个**最小化、可启动**的 img 镜像。
> 适配 x86 UEFI / ARM / 树莓派 / 飞牛 fnOS / Debian / Ubuntu，GPT 与 MBR 都支持。

![platform](https://img.shields.io/badge/platform-x86%20%7C%20ARM-2f81f7)
![shell](https://img.shields.io/badge/shell-bash-4eaa25)
![filesystems](https://img.shields.io/badge/fs-ext4%20%7C%20xfs%20%7C%20btrfs%20%7C%20f2fs-8957e5)
![boot](https://img.shields.io/badge/boot-UEFI%20%7C%20BIOS-9cf)

---

## 为什么有这个

[`nanhantianyi/rpi-backup`](https://github.com/nanhantianyi/rpi-backup)（294★）的思路很好——运行时把系统 rsync 进一个镜像文件——但它写死了树莓派的布局：

| rpi-backup 的假设 | 真实世界的机器 |
|---|---|
| `/dev/mmcblk0p1`、`p2` | 可能是 `/dev/sda`、`/dev/nvme0n1`、`/dev/mmcblk2` |
| MBR + 2 个分区 | GPT + 3 个及以上分区 |
| 替换 `PARTUUID` 到 fstab/cmdline.txt | 很多系统用 `UUID`，且没有 cmdline.txt |
| 只支持 ext4 | xfs / btrfs / f2fs |
| 不排除数据卷 | `/vol1`、`/vol2` 几百 GB 会被一起拷 |

这个脚本保留思路，把上面这些全部通用化：

## 特性

- **自动识别**：系统盘、root 分区号、ESP/boot 分区（`/boot/efi`、`/boot/firmware`、`/boot`）、分区表类型（GPT/MBR）、文件系统类型；
- **UUID / PARTUUID 原样保留**：格式化新分区时直接沿用原 UUID（ext4 `-U`、vfat `-i`、xfs/btrfs 同理）并写回 PARTUUID →
  **fstab / grub.cfg / cmdline.txt 一个字都不用改**，恢复后直接能启动；
- **自动排除**：所有非 `/` 的挂载点（数据卷、/boot/efi、tmpfs 等）、`/swapfile`、以及镜像文件自己；
- **最小镜像**：只装已用空间（`已用 × 1.15 + 512MB`），不是整盘 dd；
- **可选 zstd 压缩**；
- **dry-run**：只打印识别结果和预计大小，不写任何东西。

## 支持范围

| 项目 | 支持 |
|---|---|
| 分区表 | GPT、MBR |
| 启动 | UEFI（ESP）、BIOS（/boot 独立分区或 root 内） |
| root 文件系统 | ext2/ext3/ext4、xfs、btrfs、f2fs |
| ESP 位置 | `/boot/efi`、`/boot/firmware`、`/boot` |
| 平台 | x86_64、ARM64、ARMv7（树莓派等） |
| 不支持 | LUKS 加密根、根分区在软 RAID/LVM 上、btrfs 子卷结构 |

## 用法

```bash
# 1) 先看它会怎么做（不写文件）
sudo bash system-online-backup.sh --dry-run

# 2) 备份（镜像放在数据盘/移动硬盘上，别放系统盘）
sudo bash system-online-backup.sh -o /vol2/backup-$(date +%F).img

# 3) 压缩（可选）
sudo bash system-online-backup.sh -o /vol2/backup.img --zstd
```

输出示例：

```
[18:42:24] 系统盘      : /dev/mmcblk2 (gpt)
[18:42:24] root        : /dev/mmcblk2p2  ext4  UUID=3809cdec-...
[18:42:24] boot/ESP    : /dev/mmcblk2p1 -> /boot/efi  vfat  UUID=52C3-5AD8
[18:42:24] swapfile    : 排除 4096MB（恢复后需重建）
[18:42:24] 镜像大小    : root 8813MB + ESP 64MB ≈ 8881MB
```

> ⚠️ **不要把镜像直接建在 SMB/NFS 上再做 loop 挂载**：ext4 元数据是随机写，
> 经过网络会慢到几十 KB/s。正确做法是**先建在本地盘**，完成后整体拷到共享目录（顺序写，10 MB/s 以上）。

## 恢复

```bash
# 1) 写盘（务必确认目标盘，写错会丢数据）
sudo dd if=backup.img of=/dev/sdX bs=4M status=progress conv=fsync

# 2) 目标盘比镜像大：扩容 root 分区
sudo parted /dev/sdX resizepart 2 100%
sudo partx -u /dev/sdX
sudo resize2fs /dev/sdXp2          # xfs 用 xfs_growfs /，btrfs 用 btrfs filesystem resize max /

# 3) 重建 swapfile（备份时排除了）
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile

# 4) 如果 UEFI 启动项丢失
sudo efibootmgr -c -d /dev/sdX -p 1 -L fnOS -l '\EFI\BOOT\BOOTX64.EFI'
```

## 实测过的设备

| 设备 | 系统 | 源盘 | 镜像 | 结果 |
|---|---|---|---|---|
| InFocus KJ-ONE（Foxconn BayTrail，32 位 UEFI） | 飞牛 fnOS / Debian 12 | 29G eMMC | **8.7G** | 挂载校验通过，UUID/PARTUUID 一致 |
| Foxconn Kangaroo MD2B（Cherry Trail） | 飞牛 fnOS / Debian 12 | 58G eMMC + 数据卷 | 16G | 挂载校验通过，`/vol1` `/vol2` 已排除 |
| 树莓派 | — | — | — | 逻辑上支持（MBR + `/boot` vfat），**未实机测试** |

## 限制

- **在线备份是文件级一致**：运行中的数据库 / Docker 可能拷到半写文件。需要严格一致时先 `docker stop` 或停服务；
- **LUKS / 软 RAID 根**不支持（脚本会直接报错退出）；
- **btrfs 子卷**只做扁平拷贝，子卷结构会丢；
- 镜像是**稀疏文件**，拷到不支持 sparse 的文件系统时会展开成完整大小。

## 思路来源

- [nanhantianyi/rpi-backup](https://github.com/nanhantianyi/rpi-backup)：在线 rsync 进镜像、最小化、恢复后 resize 的原始思路；
- [raspiBackup](https://www.linux-tips-and-tricks.de/en/raspberry/raspibackup)：树莓派生态里成熟的同类工具（在线、最小镜像、支持 CIFS/NFS），但只面向 RPi。

## License

[MIT](LICENSE)
