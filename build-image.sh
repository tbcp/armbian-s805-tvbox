#!/usr/bin/env bash
# Build a ready-to-boot SD card image for an Amlogic S805 TV box with its stock
# u-boot, from the official Armbian "Onecloud" community image. No root needed.
#
# Boot partition (FAT):  aml_autoscript (+ .zip)   one-time boot-order change
#                        s805_autoscript           boots Armbian on the stock u-boot
#                        dtb/meson8b-xsr.dtb       SD slot on the faster sdhc controller
#                        dtb.img                   fallback copy of the stock DTB
# Root partition (ext4): CPU pinned to 1.536 GHz   (prevents multi-second freezes)
#                        stable eth0 MAC           (generated on first boot, or MAC=...)
#                        APT hook                  keeps meson8b-xsr.dtb in sync with kernel updates
#
# Requirements: curl xz sha256sum fdisk mkimage (u-boot-tools) mtools debugfs (e2fsprogs) python3
#
# Usage: ./build-image.sh [output.img]
#   IMG_XZ=/path/to/Armbian_...img.xz ./build-image.sh   use an already downloaded image
#   MAC=aa:bb:cc:dd:ee:ff ./build-image.sh               use this MAC instead of a generated one

set -euo pipefail

IMG_URL="https://github.com/armbian/community/releases/download/26.11.0-trunk.130/Armbian_community_26.11.0-trunk.130_Onecloud_trixie_current_6.12.28_minimal.img.xz"
IMG_SHA256="5d7ae7515a4f54327cf1b2a0d7f05d4c48fee23a4714dfe4f4b7c5cdb65b6400"
# meson8b-mxq.dtb in that image; boot/meson8b-xsr.dtb was built from exactly this file
MXQ_DTB_SHA256="70f4af6ceb956665c8d47ae68686fcc9b5003854ad8d213faff75cd8cd6efc39"

REPO="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$PWD/armbian-s805.img}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MTOOLS_SKIP_CHECK=1

for t in curl xz sha256sum fdisk mkimage mcopy debugfs e2fsck python3; do
  command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
done
if [ -n "${MAC:-}" ] && ! [[ "$MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
  echo "MAC must look like aa:bb:cc:dd:ee:ff"; exit 1
fi

# --- 1. official image ------------------------------------------------------
if [ -n "${IMG_XZ:-}" ]; then
  echo ">> using $IMG_XZ"
  ln -s "$(realpath "$IMG_XZ")" "$WORK/armbian.img.xz"
else
  echo ">> downloading the official Armbian image"
  curl -fL --progress-bar -o "$WORK/armbian.img.xz" "$IMG_URL"
fi
echo "$IMG_SHA256  $WORK/armbian.img.xz" | sha256sum -c --quiet - || { echo "checksum mismatch"; exit 1; }
echo ">> decompressing to $OUT"
xz -dc "$WORK/armbian.img.xz" > "$OUT"

read -r P1_START < <(fdisk -l -o Device,Start "$OUT" | awk -v i="$OUT" '$1==i"1"{print $2}')
read -r P2_START P2_SECTORS < <(fdisk -l -o Device,Start,Sectors "$OUT" | awk -v i="$OUT" '$1==i"2"{print $2, $3}')
[ -n "$P1_START" ] && [ -n "$P2_START" ] || { echo "unexpected partition layout"; exit 1; }
FAT="$OUT@@$((P1_START * 512))"

# --- 2. boot partition ------------------------------------------------------
echo ">> boot partition: aml_autoscript, s805_autoscript, meson8b-xsr.dtb"
for s in aml_autoscript s805_autoscript; do
  mkimage -C none -A arm -T script -n "$s" -d "$REPO/boot/$s.cmd" "$WORK/$s" >/dev/null
done
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").write(sys.argv[2], "aml_autoscript")' \
  "$WORK/aml_autoscript.zip" "$WORK/aml_autoscript"
mcopy -o -i "$FAT" "$WORK/aml_autoscript" "$WORK/aml_autoscript.zip" "$WORK/s805_autoscript" \
  "$REPO/boot/aml_autoscript.cmd" "$REPO/boot/s805_autoscript.cmd" ::/
mcopy -n -i "$FAT" ::/dtb/meson8b-mxq.dtb "$WORK/mxq.dtb"
mcopy -o -i "$FAT" "$WORK/mxq.dtb" ::/dtb.img
if echo "$MXQ_DTB_SHA256  $WORK/mxq.dtb" | sha256sum -c --quiet - 2>/dev/null; then
  mcopy -o -i "$FAT" "$REPO/boot/meson8b-xsr.dtb" ::/dtb/meson8b-xsr.dtb
else
  echo "   WARNING: stock DTB differs from the one meson8b-xsr.dtb was built from;"
  echo "   skipping it (SD runs on the slower sdio controller until the APT hook rebuilds it)"
fi

# --- 3. root partition ------------------------------------------------------
echo ">> root partition: CPU frequency, MAC service, APT hook"
dd if="$OUT" of="$WORK/root.img" bs=512 skip="$P2_START" count="$P2_SECTORS" status=none

debugfs -R "cat /etc/default/cpufrequtils" "$WORK/root.img" 2>/dev/null > "$WORK/cpufrequtils"
grep -q '^GOVERNOR=' "$WORK/cpufrequtils" || { echo "no /etc/default/cpufrequtils in image"; exit 1; }
sed -i -e 's/^GOVERNOR=.*/GOVERNOR=performance/' \
       -e 's/^MIN_SPEED=.*/MIN_SPEED=1536000/' \
       -e 's/^MAX_SPEED=.*/MAX_SPEED=1536000/' "$WORK/cpufrequtils"

# files to install:  source  target  mode
FILES=(
  "$WORK/cpufrequtils"                                   /etc/default/cpufrequtils             0644
  "$REPO/rootfs/usr/local/sbin/xsr-dtb-build"            /usr/local/sbin/xsr-dtb-build         0755
  "$REPO/rootfs/usr/local/sbin/s805-pin-mac"             /usr/local/sbin/s805-pin-mac          0755
  "$REPO/rootfs/etc/systemd/system/s805-pin-mac.service" /etc/systemd/system/s805-pin-mac.service 0644
  "$REPO/rootfs/etc/apt/apt.conf.d/99xsr-dtb"            /etc/apt/apt.conf.d/99xsr-dtb         0644
)
if [ -n "${MAC:-}" ]; then
  printf '# Stable MAC for eth0 (set at image build time).\n[Match]\nOriginalName=eth0\n\n[Link]\nMACAddress=%s\n' \
    "${MAC,,}" > "$WORK/10-eth0-mac.link"
  FILES+=("$WORK/10-eth0-mac.link" /etc/systemd/network/10-eth0-mac.link 0644)
fi

WANTS=/etc/systemd/system/network-pre.target.wants
{
  for ((i = 0; i < ${#FILES[@]}; i += 3)); do
    src=${FILES[i]} dst=${FILES[i+1]} mode=${FILES[i+2]}
    echo "rm $dst"
    echo "write $src $dst"
    echo "sif $dst mode 0100${mode#0}"
    echo "sif $dst uid 0"
    echo "sif $dst gid 0"
  done
  echo "mkdir $WANTS"
  echo "symlink $WANTS/s805-pin-mac.service /etc/systemd/system/s805-pin-mac.service"
} > "$WORK/debugfs.cmd"
debugfs -w -f "$WORK/debugfs.cmd" "$WORK/root.img" >/dev/null 2>&1

# verify everything landed, then write the partition back
for ((i = 0; i < ${#FILES[@]}; i += 3)); do
  debugfs -R "cat ${FILES[i+1]}" "$WORK/root.img" 2>/dev/null | cmp -s - "${FILES[i]}" \
    || { echo "failed to write ${FILES[i+1]}"; exit 1; }
done
debugfs -R "stat $WANTS/s805-pin-mac.service" "$WORK/root.img" 2>/dev/null | grep -q 'Type: symlink' \
  || { echo "failed to enable s805-pin-mac.service"; exit 1; }
e2fsck -fn "$WORK/root.img" >/dev/null 2>&1 || { echo "rootfs check failed"; exit 1; }
dd if="$WORK/root.img" of="$OUT" bs=512 seek="$P2_START" conv=notrunc status=none

echo
echo "Done: $OUT"
echo "Write it to an SD card, e.g.:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
