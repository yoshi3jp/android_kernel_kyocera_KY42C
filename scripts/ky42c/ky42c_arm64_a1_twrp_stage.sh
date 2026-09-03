#!/usr/bin/env bash
set -Eeuo pipefail

# KY-42C ARM64 A1: stage the clean AArch64 kernel and DT artifacts for the
# already-working 32-bit TWRP recovery environment.
#
# This script deliberately does NOT flash anything and, by default, does NOT
# modify the TWRP device tree.  It creates a self-contained staging directory
# containing:
#   kernel   = ARM64 Image.gz
#   dtb.img  = ARM64 MT6761 base DTB
#   dtbo.img = Android DTBO image containing only FLARE05[0510]
#
# The TWRP device tree remains TARGET_ARCH=arm because recovery userspace is
# intentionally still 32-bit.  TARGET_FORCE_PREBUILT_KERNEL means the kernel
# payload itself can be AArch64 independently of recovery userspace ISA.
#
# Usage:
#   ./scripts/ky42c/ky42c_arm64_a1_twrp_stage.sh \
#       /path/to/android_device_kyocera_KY-42C \
#       /path/to/mkdtimg \
#       [--install]
#
# --install copies the staged files into DEVICE_TREE/prebuilt after first
# preserving the existing three prebuilts in the staging directory.  It does
# not invoke the Android/TWRP build and does not flash recovery.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

DEVICE_TREE="${1:-}"
MKDTIMG="${2:-}"
INSTALL=0
[[ "${3:-}" == "--install" ]] && INSTALL=1
[[ -n "$DEVICE_TREE" ]] || die "TWRP device-tree path is required"
[[ -n "$MKDTIMG" ]] || die "mkdtimg path is required"
DEVICE_TREE="$(cd "$DEVICE_TREE" && pwd)"
MKDTIMG="$(readlink -f "$MKDTIMG")"
[[ -x "$MKDTIMG" ]] || die "mkdtimg is not executable: $MKDTIMG"

KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
STAGE="$KERNEL_DIR/out-ky42c-arm64-a1-twrp"
PREBUILT="$DEVICE_TREE/prebuilt"

RAW_IMAGE="$OUT/arch/arm64/boot/Image"
GZ_IMAGE="$OUT/arch/arm64/boot/Image.gz"
BASE_DTB="$OUT/arch/arm64/boot/dts/mediatek/mt6761.dtb"
OVERLAY_DTB="$OUT/arch/arm64/boot/dts/mediatek/mt6761-FLARE05[0510].dtb"
MERGED_DTB="$OVERLAY_DTB.merge"

EXPECTED_CONFIG_SHA="9e018f98d724208780d71a75f38692ee3b2ab97b58792205762a8fc952cd7f3b"
EXPECTED_DEFCONFIG_SHA="0822f8dc4131243054ab64578178fa715325e30a62b6d73457f1caf17446396b"
EXPECTED_BASE_DTB_SHA="ad103f7ffc0447f38617eb1fa2ff8f819add8572b7b5843ae65071fa33dd8d76"
EXPECTED_OVERLAY_DTB_SHA="532bc95c74b2dcc57d027d2fa17f4cf30c145e349867a0a0281899e0847f280d"
EXPECTED_MERGED_DTB_SHA="119fb97f427495cfcd000c35a69fcd2d2f57a06bfd69d37c373e3699ff135ddd"

for f in "$RAW_IMAGE" "$GZ_IMAGE" "$BASE_DTB" "$OVERLAY_DTB" "$MERGED_DTB" "$OUT/.config" "$OUT/defconfig"; do
    [[ -s "$f" ]] || die "required A0 artifact missing: $f"
done
[[ -f "$DEVICE_TREE/BoardConfig.mk" ]] || die "BoardConfig.mk missing from $DEVICE_TREE"
[[ -d "$PREBUILT" ]] || die "prebuilt directory missing: $PREBUILT"

# We want a clean, committed kernel source for a hardware test candidate.
git -C "$KERNEL_DIR" diff --quiet || die "kernel working tree has unstaged changes"
git -C "$KERNEL_DIR" diff --cached --quiet || die "kernel working tree has staged changes"

check_sha() {
    local expected="$1" file="$2" label="$3" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "$label hash changed: expected $expected, got $actual ($file)"
}

check_sha "$EXPECTED_CONFIG_SHA" "$OUT/.config" "A0 .config"
check_sha "$EXPECTED_DEFCONFIG_SHA" "$OUT/defconfig" "A0 defconfig"
check_sha "$EXPECTED_BASE_DTB_SHA" "$BASE_DTB" "ARM64 base DTB"
check_sha "$EXPECTED_OVERLAY_DTB_SHA" "$OVERLAY_DTB" "ARM64 FLARE05[0510] overlay"
check_sha "$EXPECTED_MERGED_DTB_SHA" "$MERGED_DTB" "ARM64 merged validation DTB"

# Confirm Image.gz is exactly gzip(Image), not a different packaging artifact.
gzip -t "$GZ_IMAGE"
raw_sha="$(sha256sum "$RAW_IMAGE" | awk '{print $1}')"
dec_sha="$(gzip -dc "$GZ_IMAGE" | sha256sum | awk '{print $1}')"
[[ "$raw_sha" == "$dec_sha" ]] || die "Image.gz does not decompress exactly to Image"

python3 - "$RAW_IMAGE" <<'PY'
import struct, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    h = f.read(64)
if len(h) < 64 or h[56:60] != b'ARMd':
    raise SystemExit('ERROR: staged raw kernel is not an ARM64 Linux Image')
print('arm64_image_magic=ARMd')
print('arm64_text_offset=0x%x' % struct.unpack_from('<Q', h, 8)[0])
print('arm64_image_size=0x%x' % struct.unpack_from('<Q', h, 16)[0])
print('arm64_flags=0x%x' % struct.unpack_from('<Q', h, 24)[0])
PY

# Guard the recovery assumptions that have already been hardware validated.
grep -Fq 'TARGET_ARCH := arm' "$DEVICE_TREE/BoardConfig.mk" ||
    die "TWRP userspace is no longer configured as 32-bit ARM"
grep -Fq 'TARGET_FORCE_PREBUILT_KERNEL := true' "$DEVICE_TREE/BoardConfig.mk" ||
    die "TWRP no longer forces a prebuilt kernel"
grep -Fq 'BOARD_BOOTIMG_HEADER_VERSION := 2' "$DEVICE_TREE/BoardConfig.mk" ||
    die "unexpected recovery boot header version"
grep -Fq 'BOARD_KERNEL_PAGESIZE := 2048' "$DEVICE_TREE/BoardConfig.mk" ||
    die "unexpected recovery boot image page size"
grep -Fq 'BOARD_INCLUDE_RECOVERY_DTBO := true' "$DEVICE_TREE/BoardConfig.mk" ||
    die "TWRP recovery-DTBO packaging is no longer enabled"

rm -rf "$STAGE"
mkdir -p "$STAGE/stock-prebuilt" "$STAGE/a1-prebuilt"

note "Preserving current TWRP prebuilts"
for n in kernel dtb.img dtbo.img; do
    [[ -s "$PREBUILT/$n" ]] || die "current TWRP prebuilt missing: $PREBUILT/$n"
    cp -a "$PREBUILT/$n" "$STAGE/stock-prebuilt/$n"
done
sha256sum "$STAGE"/stock-prebuilt/* | tee "$STAGE/stock-prebuilt.sha256"

note "Staging ARM64 A1 recovery prebuilts"
cp "$GZ_IMAGE" "$STAGE/a1-prebuilt/kernel"
cp "$BASE_DTB" "$STAGE/a1-prebuilt/dtb.img"

# A0 deliberately carries only the runtime-tested FLARE05[0510] overlay.
# Build a one-entry Android DT table for the recovery_dtbo section.  The
# selected entry therefore becomes index 0 for this controlled A1 image.
"$MKDTIMG" create "$STAGE/a1-prebuilt/dtbo.img" \
    --page_size=2048 \
    "$OVERLAY_DTB"

[[ -s "$STAGE/a1-prebuilt/dtbo.img" ]] || die "mkdtimg produced no DTBO image"

note "A1 staging manifest"
{
    printf 'kernel_git=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    printf 'kernel_branch=%s\n' "$(git -C "$KERNEL_DIR" symbolic-ref --short -q HEAD || echo detached)"
    printf 'config_sha256=%s\n' "$(sha256sum "$OUT/.config" | awk '{print $1}')"
    printf 'defconfig_sha256=%s\n' "$(sha256sum "$OUT/defconfig" | awk '{print $1}')"
    printf 'twrp_git=%s\n' "$(git -C "$DEVICE_TREE" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'twrp_branch=%s\n' "$(git -C "$DEVICE_TREE" symbolic-ref --short -q HEAD 2>/dev/null || echo unknown)"
    printf 'mkdtimg=%s\n' "$MKDTIMG"
    printf 'merged_validation_dtb_sha256=%s\n' "$(sha256sum "$MERGED_DTB" | awk '{print $1}')"
    printf '\nA1 prebuilt hashes:\n'
    sha256sum "$STAGE"/a1-prebuilt/*
    printf '\nA1 prebuilt sizes:\n'
    stat -c '%12s  %n' "$STAGE"/a1-prebuilt/*
} | tee "$STAGE/manifest.txt"

cat > "$STAGE/README.txt" <<EOF
KY-42C ARM64 A1 TWRP recovery staging directory

Purpose:
  Boot the clean AArch64 Linux 4.9 kernel under the already-working 32-bit
  TWRP recovery userspace.  Android/system boot remains untouched.

Staged replacements:
  prebuilt/kernel   <- ARM64 Image.gz
  prebuilt/dtb.img  <- ARM64 mt6761.dtb base
  prebuilt/dtbo.img <- Android DTBO image containing FLARE05[0510] only

Important packaging rule:
  Do NOT append or preserve the old ARM32 kernel_dtb behind Image.gz.  The
  ARM64 candidate uses the boot-header-v2 DTB field plus recovery_dtbo.
  A TWRP source build from these three prebuilts naturally follows that model.

The existing TWRP ramdisk/userspace remains ARM32 by design.  CONFIG_COMPAT in
this kernel is required for that userspace.
EOF

if (( INSTALL )); then
    note "Installing staged A1 prebuilts into TWRP device tree"
    cp "$STAGE/a1-prebuilt/kernel" "$PREBUILT/kernel"
    cp "$STAGE/a1-prebuilt/dtb.img" "$PREBUILT/dtb.img"
    cp "$STAGE/a1-prebuilt/dtbo.img" "$PREBUILT/dtbo.img"
    printf '\nTWRP device-tree diff/status after install:\n'
    git -C "$DEVICE_TREE" status --short || true
    sha256sum "$PREBUILT/kernel" "$PREBUILT/dtb.img" "$PREBUILT/dtbo.img"
else
    printf '\nStaged only; TWRP device tree was not modified.\n'
    printf 'To install the three staged prebuilts, rerun with --install.\n'
fi

printf '\nARM64_A1_TWRP_STAGE_COMPLETE\n'
