#!/usr/bin/env bash
set -Eeuo pipefail

# KY-42C ARM64 A0: first complete AArch64 kernel build.
#
# Preconditions:
#   1. ky42c_xenial_arm64_a0_config.sh completed successfully.
#   2. ky42c_xenial_arm64_a0_dt.sh completed with ARM64_A0_DT_COMPLETE.
#
# This stage intentionally builds Image.gz explicitly instead of invoking the
# MediaTek default "all" target, because CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE
# changes KBUILD_IMAGE to Image.gz-dtb.  The Android boot-v2 experiment will
# use Image.gz plus a separate DTB field; appended-DTB packaging is not yet a
# bring-up assumption.
#
# Usage:
#   ./scripts/ky42c/ky42c_xenial_arm64_a0_build.sh \
#       /media/.../working \
#       [kernel-directory-name] \
#       [/absolute/path/to/aosp-aarch64-linux-android-4.9]

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

WORK_ROOT="${1:-}"
KERNEL_NAME="${2:-ky42c-kernel-reconstructed}"
AARCH64_TC_ARG="${3:-}"
IMAGE="${KY42C_BUILD_IMAGE:-ky42c-kernel-xenial:16.04-v2}"

# These hashes identify the A0 configuration already validated on 2026-09-03.
EXPECTED_CONFIG_SHA="9e018f98d724208780d71a75f38692ee3b2ab97b58792205762a8fc952cd7f3b"
EXPECTED_DEFCONFIG_SHA="0822f8dc4131243054ab64578178fa715325e30a62b6d73457f1caf17446396b"

[[ -n "$WORK_ROOT" ]] || die "working root is required"
WORK_ROOT="$(cd "$WORK_ROOT" && pwd)"
KERNEL_DIR="$WORK_ROOT/$KERNEL_NAME"
[[ -f "$KERNEL_DIR/Makefile" ]] || die "kernel tree not found: $KERNEL_DIR"

if [[ -n "$AARCH64_TC_ARG" ]]; then
    AARCH64_TC="$(cd "$AARCH64_TC_ARG" && pwd)"
else
    AARCH64_TC="$WORK_ROOT/aosp-aarch64-linux-android-4.9"
fi

[[ -x "$AARCH64_TC/bin/aarch64-linux-android-gcc" ]] ||
    die "AOSP AArch64 GCC 4.9 not found: $AARCH64_TC/bin/aarch64-linux-android-gcc"
command -v docker >/dev/null 2>&1 || die "docker not found"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Docker image not found: $IMAGE"

OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
[[ -f "$OUT/.config" ]] || die "missing $OUT/.config; run the A0 config wrapper first"
[[ -f "$OUT/defconfig" ]] || die "missing $OUT/defconfig; run the A0 config wrapper first"

actual_config_sha="$(sha256sum "$OUT/.config" | awk '{print $1}')"
actual_defconfig_sha="$(sha256sum "$OUT/defconfig" | awk '{print $1}')"
[[ "$actual_config_sha" == "$EXPECTED_CONFIG_SHA" ]] ||
    die "A0 .config hash changed: expected $EXPECTED_CONFIG_SHA, got $actual_config_sha"
[[ "$actual_defconfig_sha" == "$EXPECTED_DEFCONFIG_SHA" ]] ||
    die "A0 savedefconfig hash changed: expected $EXPECTED_DEFCONFIG_SHA, got $actual_defconfig_sha"

if [[ -e "$KERNEL_DIR/.config" || -e "$KERNEL_DIR/include/config/auto.conf" ]]; then
    die "stale in-tree build state detected; clean the source tree before O= ARM64 build"
fi

MOUNTS=(-v "$WORK_ROOT:$WORK_ROOT")
case "$AARCH64_TC/" in
    "$WORK_ROOT/"*) ;;
    *) MOUNTS+=(-v "$AARCH64_TC:$AARCH64_TC:ro") ;;
esac

note "Building first complete KY-42C ARM64 A0 kernel"
echo "    WORK_ROOT=$WORK_ROOT"
echo "    KERNEL_DIR=$KERNEL_DIR"
echo "    OUT=$OUT"
echo "    AARCH64_TC=$AARCH64_TC"
echo "    IMAGE=$IMAGE"
echo "    config_sha256=$actual_config_sha"
echo "    defconfig_sha256=$actual_defconfig_sha"

docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e WORK_ROOT="$WORK_ROOT" \
    -e KERNEL_NAME="$KERNEL_NAME" \
    -e AARCH64_TC="$AARCH64_TC" \
    -e EXPECTED_CONFIG_SHA="$EXPECTED_CONFIG_SHA" \
    -e EXPECTED_DEFCONFIG_SHA="$EXPECTED_DEFCONFIG_SHA" \
    "${MOUNTS[@]}" \
    -w "$KERNEL_DIR" \
    "$IMAGE" \
    bash -s <<'KY42C_ARM64_BUILD_INNER'
set -Eeuo pipefail

KERNEL_DIR="$WORK_ROOT/$KERNEL_NAME"
OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
CROSS_COMPILE="$AARCH64_TC/bin/aarch64-linux-android-"
IMAGE_LOG="$OUT/arm64-a0-image-build.log"
DT_LOG="$OUT/arm64-a0-dt-recheck.log"
SUMMARY="$OUT/arm64-a0-build-summary.txt"

VMLINUX="$OUT/vmlinux"
RAW_IMAGE="$OUT/arch/arm64/boot/Image"
GZ_IMAGE="$OUT/arch/arm64/boot/Image.gz"
BASE_DTB="$OUT/arch/arm64/boot/dts/mediatek/mt6761.dtb"
DTBO="$OUT/arch/arm64/boot/dts/mediatek/mt6761-FLARE05[0510].dtb"
MERGED="$DTBO.merge"
MTK_DTB="$OUT/arch/arm64/boot/mtk.dtb"

printf '\nEnvironment:\n'
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
/usr/bin/python2.7 --version
"${CROSS_COMPILE}gcc" --version | head -n 3
"${CROSS_COMPILE}ld" --version | head -n 1
printf 'kernel_git=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
printf 'config_sha256=%s\n' "$(sha256sum "$OUT/.config" | awk '{print $1}')"
printf 'defconfig_sha256=%s\n' "$(sha256sum "$OUT/defconfig" | awk '{print $1}')"

[[ "$(sha256sum "$OUT/.config" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA" ]] || exit 3
[[ "$(sha256sum "$OUT/defconfig" | awk '{print $1}')" == "$EXPECTED_DEFCONFIG_SHA" ]] || exit 3

printf '\n==> Revalidate Kconfig before compilation\n'
make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    olddefconfig

post_olddef_sha="$(sha256sum "$OUT/.config" | awk '{print $1}')"
printf 'post_olddefconfig_sha256=%s\n' "$post_olddef_sha"
[[ "$post_olddef_sha" == "$EXPECTED_CONFIG_SHA" ]] || {
    echo "ERROR: olddefconfig changed the validated A0 configuration" >&2
    exit 3
}

printf '\n==> Build vmlinux -> Image -> Image.gz\n'
rm -f "$IMAGE_LOG" "$DT_LOG" "$SUMMARY"
set +e
make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    -j"$(nproc)" \
    Image.gz 2>&1 | tee "$IMAGE_LOG"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 ]]; then
    printf '\nARM64 Image.gz build failed (rc=%d). Full log:\n  %s\n' "$rc" "$IMAGE_LOG" >&2
    printf '\nFirst error-like lines:\n' >&2
    grep -nE '(^|[[:space:]])(error:|fatal:|Error|ERROR|undefined reference|No such file|not found|collect2:|ld:)' \
        "$IMAGE_LOG" | head -n 80 >&2 || true
    exit "$rc"
fi

printf '\n==> Rebuild/recheck A0 DT artifacts against the completed kernel tree\n'
set +e
make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    -j"$(nproc)" \
    dtbs 2>&1 | tee "$DT_LOG"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 ]]; then
    printf '\nDT recheck failed after successful kernel build (rc=%d). Log:\n  %s\n' "$rc" "$DT_LOG" >&2
    exit "$rc"
fi

printf '\n==> Required kernel artifacts\n'
for f in "$VMLINUX" "$RAW_IMAGE" "$GZ_IMAGE" "$BASE_DTB" "$DTBO" "$MERGED"; do
    [[ -s "$f" ]] || {
        echo "ERROR: required build artifact missing or empty: $f" >&2
        exit 4
    }
done

gzip -t "$GZ_IMAGE"
raw_sha="$(sha256sum "$RAW_IMAGE" | awk '{print $1}')"
gz_dec_sha="$(gzip -dc "$GZ_IMAGE" | sha256sum | awk '{print $1}')"
[[ "$raw_sha" == "$gz_dec_sha" ]] || {
    echo "ERROR: Image.gz does not decompress byte-for-byte to Image" >&2
    exit 4
}

# ARM64 Linux Image header magic is 0x644d5241 at offset 0x38, serialized as
# the four bytes 41 52 4d 64 ("ARMd") in the little-endian Image header.
/usr/bin/python2.7 - "$RAW_IMAGE" <<'PY'
import os
import struct
import sys
p = sys.argv[1]
with open(p, 'rb') as f:
    h = f.read(64)
if len(h) < 64:
    raise SystemExit('ERROR: Image shorter than ARM64 header')
if h[56:60] != 'ARMd':
    raise SystemExit('ERROR: ARM64 Image magic missing at offset 0x38: %r' % (h[56:60],))
text_offset = struct.unpack_from('<Q', h, 8)[0]
image_size = struct.unpack_from('<Q', h, 16)[0]
flags = struct.unpack_from('<Q', h, 24)[0]
print('arm64_image_magic=ARMd')
print('arm64_text_offset=0x%x' % text_offset)
print('arm64_header_image_size=0x%x' % image_size)
print('arm64_header_flags=0x%x' % flags)
print('arm64_file_size=0x%x' % os.path.getsize(p))
PY

printf '\nELF identity:\n'
file "$VMLINUX"
"${CROSS_COMPILE}readelf" -h "$VMLINUX" | grep -E 'Class:|Data:|Machine:|Type:|Entry point address:'
"${CROSS_COMPILE}objdump" -f "$VMLINUX" | head -n 8

machine="$("${CROSS_COMPILE}readelf" -h "$VMLINUX" | awk -F: '/Machine:/ {gsub(/^[ \t]+/, "", $2); print $2}')"
[[ "$machine" == "AArch64" ]] || {
    echo "ERROR: vmlinux machine is not AArch64: $machine" >&2
    exit 4
}

printf '\nUnresolved-symbol report (informational after final vmlinux link):\n'
unresolved="$OUT/arm64-a0-vmlinux-undefined.txt"
"${CROSS_COMPILE}nm" -u "$VMLINUX" > "$unresolved" || true
printf 'undefined_symbol_lines=%s\n' "$(wc -l < "$unresolved")"
head -n 40 "$unresolved" || true

printf '\nArtifact hashes and sizes:\n'
{
    printf 'kernel_git=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
    printf 'config_sha256=%s\n' "$(sha256sum "$OUT/.config" | awk '{print $1}')"
    printf 'defconfig_sha256=%s\n' "$(sha256sum "$OUT/defconfig" | awk '{print $1}')"
    for f in "$VMLINUX" "$RAW_IMAGE" "$GZ_IMAGE" "$BASE_DTB" "$DTBO" "$MERGED"; do
        printf '%12d  %s  %s\n' "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')" "$f"
    done
    if [[ -s "$MTK_DTB" ]]; then
        printf '%12d  %s  %s\n' "$(stat -c %s "$MTK_DTB")" "$(sha256sum "$MTK_DTB" | awk '{print $1}')" "$MTK_DTB"
    else
        printf 'NOTE: %s is not produced by the kernel dtbs target.\n' "$MTK_DTB"
        printf '      drvgen.mk writes this path into dtbimg.cfg for higher-level MediaTek packaging.\n'
    fi
} | tee "$SUMMARY"

printf '\nKernel version string candidates:\n'
strings "$RAW_IMAGE" | grep -m 3 '^Linux version ' || true

printf '\nResolved defconfig is ready to freeze into the repository:\n'
printf '  %s\n' "$OUT/defconfig"
printf '  sha256=%s\n' "$(sha256sum "$OUT/defconfig" | awk '{print $1}')"
printf 'Upload or provide this 11 KiB file after the build so it can be committed verbatim.\n'

printf '\nARM64_A0_KERNEL_BUILD_COMPLETE\n'
KY42C_ARM64_BUILD_INNER
