#!/usr/bin/env bash
# Build a ready-to-boot SD card image for an Amlogic S805 TV box with its stock
# u-boot, from the official Armbian "Onecloud" community image. No root needed.
#
# Boot partition (FAT):  aml_autoscript (+ .zip)   one-time boot-order change
#                        s805_autoscript           boots Armbian on the stock u-boot
#                        dtb/meson8b-xsr.dtb       SD on the faster sdhc controller, Wi-Fi
#                        dtb.img                   fallback copy of the stock DTB
# Root partition (ext4): hostname s805box          (instead of Armbian's "onecloud")
#                        CPU pinned to 1.536 GHz   (prevents multi-second freezes)
#                        stable eth0 MAC           (generated on first boot, or MAC=...)
#                        APT hook                  keeps meson8b-xsr.dtb in sync with kernel updates
#
# Requirements: curl xz sha256sum fdisk mkimage (u-boot-tools) mtools debugfs (e2fsprogs) python3
#               --latest also needs dtc (device-tree-compiler) for the SD/Wi-Fi device tree
#
# Usage: ./build-image.sh [--tested | --latest] [output.img]
#   (default)   build the Armbian release this repo was tested with; if a newer
#               one exists and you run it in a terminal, you're asked whether to
#               try that instead
#   --tested    build the tested release, don't check for newer ones
#   --latest    build Armbian's newest Onecloud trixie image: UNTESTED on S805
#   IMG_XZ=/path/to/Armbian_...img.xz ./build-image.sh   use an already downloaded image
#   MAC=aa:bb:cc:dd:ee:ff ./build-image.sh               use this MAC instead of a generated one
#   BOX_HOSTNAME=mybox ./build-image.sh                  hostname (default: s805box)

set -euo pipefail

# --- the tested Armbian release ------------------------------------------------
TESTED_VER="26.11.0-trunk.130"
IMG_URL="https://github.com/armbian/community/releases/download/$TESTED_VER/Armbian_community_${TESTED_VER}_Onecloud_trixie_current_6.12.28_minimal.img.xz"
IMG_SHA256="5d7ae7515a4f54327cf1b2a0d7f05d4c48fee23a4714dfe4f4b7c5cdb65b6400"
# Armbian only keeps its last few community builds; this repo's v1.0 release has a copy
IMG_MIRROR="https://github.com/tbcp/armbian-s805-tvbox/releases/download/v1.0/${IMG_URL##*/}"
# meson8b-mxq.dtb in that image; boot/meson8b-xsr.dtb was built from exactly this file
MXQ_DTB_SHA256="70f4af6ceb956665c8d47ae68686fcc9b5003854ad8d213faff75cd8cd6efc39"

# --- where to find Armbian's newest build (ARMBIAN_LATEST_URL overrides, for testing)
LATEST_REDIRECT="https://dl.armbian.com/onecloud/Trixie_current_minimal"
SHA_BASE="https://cache.armbian.com/artifacts/onecloud/archive"
IMG_RE='^Armbian_community_([0-9.]+-trunk\.[0-9]+)_Onecloud_trixie_current_([0-9.]+)_minimal\.img\.xz$'

MODE=default OUT=""
for a in "$@"; do
  case "$a" in
    --tested) MODE=tested ;;
    --latest) MODE=latest ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) echo "unknown option: $a (see --help)"; exit 1 ;;
    *) OUT="$a" ;;
  esac
done

REPO="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MTOOLS_SKIP_CHECK=1

for t in curl xz sha256sum fdisk mkimage mcopy mdir debugfs dumpe2fs e2fsck python3; do
  command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
done
BOX_HOSTNAME="${BOX_HOSTNAME:-s805box}"
if ! [[ "$BOX_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "BOX_HOSTNAME must be lowercase letters, digits and dashes"; exit 1
fi
if [ -n "${MAC:-}" ] && ! [[ "$MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
  echo "MAC must look like aa:bb:cc:dd:ee:ff"; exit 1
fi

warn_untested() {
  echo "!! ----------------------------------------------------------------------"
  echo "!! UNTESTED: Armbian $LATEST_VER (kernel $LATEST_KERNEL)."
  echo "!! This repo was tested with $TESTED_VER. A newer build has NOT been tested on"
  echo "!! an S805 box: it may not boot, or Wi-Fi / the faster SD may be missing."
  echo "!! If it works (or doesn't), please report it in the repo's Issues."
  echo "!! ----------------------------------------------------------------------"
}

# --- 0. is there a newer Armbian build? -----------------------------------------
LATEST_URL="" LATEST_VER="" LATEST_KERNEL=""
if [ "$MODE" != tested ]; then
  LATEST_URL="${ARMBIAN_LATEST_URL:-$(curl -fsS -o /dev/null -w '%{redirect_url}' --max-time 15 "$LATEST_REDIRECT" 2>/dev/null || true)}"
  if [[ "${LATEST_URL##*/}" =~ $IMG_RE ]]; then
    LATEST_VER="${BASH_REMATCH[1]}" LATEST_KERNEL="${BASH_REMATCH[2]}"
  elif [ "$MODE" = latest ]; then
    echo "could not find Armbian's latest Onecloud trixie image (got: '${LATEST_URL:-nothing}')"; exit 1
  fi
fi
if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" != "$TESTED_VER" ]; then
  if [ "$MODE" = default ]; then
    if [ "$(printf '%s\n%s\n' "$TESTED_VER" "$LATEST_VER" | sort -V | tail -1)" = "$LATEST_VER" ]; then
      if [ -t 0 ] && [ -z "${IMG_XZ:-}" ]; then
        echo "!! A newer Armbian build is available: $LATEST_VER (kernel $LATEST_KERNEL)"
        echo "!! This repo was tested with $TESTED_VER. The newer build has NOT been tested on"
        echo "!! an S805 box: it may not boot, or Wi-Fi / the faster SD may be missing."
        read -r -p "!! Use it anyway? [y/N] " answer
        [[ "$answer" =~ ^[yY] ]] && MODE=latest
      else
        echo ">> note: Armbian $LATEST_VER is available (untested); use --latest to try it"
      fi
    fi
  fi
elif [ "$MODE" = latest ]; then
  echo ">> Armbian's latest build is the tested one ($TESTED_VER)"
  MODE=tested
fi

if [ "$MODE" = latest ]; then
  UNTESTED=1
  IMG_URL="$LATEST_URL" IMG_MIRROR=""
  read -r IMG_SHA256 sha_name < <(curl -fsSL --max-time 30 "$SHA_BASE/${LATEST_URL##*/}.sha") || true
  [ "${sha_name:-}" = "${LATEST_URL##*/}" ] && [[ "${IMG_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
    || { echo "could not get Armbian's checksum for ${LATEST_URL##*/}"; exit 1; }
  OUT="${OUT:-$PWD/armbian-s805-UNTESTED-$LATEST_VER.img}"
  warn_untested
else
  UNTESTED=0
  OUT="${OUT:-$PWD/armbian-s805.img}"
fi

# --- 1. official image ------------------------------------------------------
if [ -n "${IMG_XZ:-}" ]; then
  echo ">> using $IMG_XZ"
  ln -s "$(realpath "$IMG_XZ")" "$WORK/armbian.img.xz"
else
  echo ">> downloading ${IMG_URL##*/}"
  if ! curl -fL --progress-bar -o "$WORK/armbian.img.xz" "$IMG_URL"; then
    [ -n "$IMG_MIRROR" ] || { echo "download failed"; exit 1; }
    echo ">> not available from Armbian anymore, using the copy in this repo's v1.0 release"
    curl -fL --progress-bar -o "$WORK/armbian.img.xz" "$IMG_MIRROR" || {
      echo "!! The tested Armbian image ($TESTED_VER) isn't available anywhere anymore."
      echo "!! Use a copy you have:  IMG_XZ=/path/to/${IMG_URL##*/} $0"
      echo "!! or try Armbian's newest build (untested):  $0 --latest"
      exit 1
    }
  fi
fi
echo "$IMG_SHA256  $WORK/armbian.img.xz" | sha256sum -c --quiet - || { echo "checksum mismatch"; exit 1; }
echo ">> decompressing to $OUT"
xz -dc "$WORK/armbian.img.xz" > "$OUT"

read -r P1_START < <(fdisk -l -o Device,Start "$OUT" | awk -v i="$OUT" '$1==i"1"{print $2}')
read -r P2_START P2_SECTORS < <(fdisk -l -o Device,Start,Sectors "$OUT" | awk -v i="$OUT" '$1==i"2"{print $2, $3}')
[ -n "$P1_START" ] && [ -n "$P2_START" ] || { echo "unexpected partition layout"; exit 1; }
FAT="$OUT@@$((P1_START * 512))"
dd if="$OUT" of="$WORK/root.img" bs=512 skip="$P2_START" count="$P2_SECTORS" status=none

# sanity checks: the parts of the Armbian image that this build relies on
for f in uImage uInitrd dtb/meson8b-mxq.dtb; do
  mdir -b -i "$FAT" "::/$f" >/dev/null 2>&1 || { echo "image has no /boot/$f: unexpected Armbian layout"; exit 1; }
done
ROOT_UUID="$(dumpe2fs -h "$WORK/root.img" 2>/dev/null | awk '/^Filesystem UUID:/{print $3}')"
[[ "$ROOT_UUID" =~ ^[0-9a-f-]{36}$ ]] || { echo "can't read the root filesystem UUID"; exit 1; }

# --- 2. boot partition ------------------------------------------------------
echo ">> boot partition: aml_autoscript, s805_autoscript (root UUID $ROOT_UUID), meson8b-xsr.dtb"
cp "$REPO/boot/aml_autoscript.cmd" "$WORK/aml_autoscript.cmd"
sed "s/root=UUID=[0-9a-f-]*/root=UUID=$ROOT_UUID/" "$REPO/boot/s805_autoscript.cmd" > "$WORK/s805_autoscript.cmd"
grep -q "root=UUID=$ROOT_UUID " "$WORK/s805_autoscript.cmd" || { echo "failed to set the root UUID"; exit 1; }
for s in aml_autoscript s805_autoscript; do
  mkimage -C none -A arm -T script -n "$s" -d "$WORK/$s.cmd" "$WORK/$s" >/dev/null
done
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").write(sys.argv[2], "aml_autoscript")' \
  "$WORK/aml_autoscript.zip" "$WORK/aml_autoscript"
mcopy -o -i "$FAT" "$WORK/aml_autoscript" "$WORK/aml_autoscript.zip" "$WORK/s805_autoscript" \
  "$WORK/aml_autoscript.cmd" "$WORK/s805_autoscript.cmd" ::/
mcopy -n -i "$FAT" ::/dtb/meson8b-mxq.dtb "$WORK/mxq.dtb"
mcopy -o -i "$FAT" "$WORK/mxq.dtb" ::/dtb.img
if echo "$MXQ_DTB_SHA256  $WORK/mxq.dtb" | sha256sum -c --quiet - 2>/dev/null; then
  cp "$REPO/boot/meson8b-xsr.dtb" "$WORK/xsr.dtb"            # prebuilt, tested
elif command -v dtc >/dev/null; then
  echo "   stock DTB differs from the tested one: building meson8b-xsr.dtb from it"
  python3 -I "$REPO/rootfs/usr/local/sbin/xsr-dtb-build" "$WORK/mxq.dtb" "$WORK/xsr.dtb" | sed 's/^/   /'
else
  echo "   WARNING: stock DTB differs from the tested one and dtc isn't installed:"
  echo "   no meson8b-xsr.dtb (slower SD, no Wi-Fi). Install dtc / device-tree-compiler and rebuild,"
  echo "   or let the box do it: the APT hook builds it after the first 'apt upgrade'."
fi
[ -f "$WORK/xsr.dtb" ] && mcopy -o -i "$FAT" "$WORK/xsr.dtb" ::/dtb/meson8b-xsr.dtb

# --- 3. root partition ------------------------------------------------------
echo ">> root partition: hostname $BOX_HOSTNAME, CPU frequency, MAC service, APT hook"
debugfs -R "cat /etc/default/cpufrequtils" "$WORK/root.img" 2>/dev/null > "$WORK/cpufrequtils"
grep -q '^GOVERNOR=' "$WORK/cpufrequtils" || { echo "no /etc/default/cpufrequtils in image"; exit 1; }
sed -i -e 's/^GOVERNOR=.*/GOVERNOR=performance/' \
       -e 's/^MIN_SPEED=.*/MIN_SPEED=1536000/' \
       -e 's/^MAX_SPEED=.*/MAX_SPEED=1536000/' "$WORK/cpufrequtils"

echo "$BOX_HOSTNAME" > "$WORK/hostname"
debugfs -R "cat /etc/hosts" "$WORK/root.img" 2>/dev/null | sed "s/\bonecloud\b/$BOX_HOSTNAME/g" > "$WORK/hosts"
grep -q "$BOX_HOSTNAME" "$WORK/hosts" || { echo "unexpected /etc/hosts in image"; exit 1; }

# files to install:  source  target  mode
FILES=(
  "$WORK/hostname"                                       /etc/hostname                         0644
  "$WORK/hosts"                                          /etc/hosts                            0644
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
[ "$UNTESTED" = 1 ] && warn_untested
echo "Write it to an SD card, e.g.:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
