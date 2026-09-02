#!/usr/bin/env bash
set -Eeuo pipefail

# KY-42C ARM64 A0: build and validate the MT6761 base DTB plus the single
# runtime-tested FLARE05[0510] DTBO inside the established Xenial container.
#
# This script intentionally consumes the already-resolved
# out-ky42c-arm64-a0/.config.  Run ky42c_xenial_arm64_a0_config.sh first.
#
# Usage:
#   ./scripts/ky42c/ky42c_xenial_arm64_a0_dt.sh \
#       /media/.../working \
#       [kernel-directory-name] \
#       [/absolute/path/to/aosp-aarch64-linux-android-4.9]

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

WORK_ROOT="${1:-}"
KERNEL_NAME="${2:-ky42c-kernel-reconstructed}"
AARCH64_TC_ARG="${3:-}"
IMAGE="${KY42C_BUILD_IMAGE:-ky42c-kernel-xenial:16.04-v2}"

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
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
    die "Docker image not found: $IMAGE (run the config wrapper first or build the established Xenial image)"

OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
[[ -f "$OUT/.config" ]] ||
    die "resolved ARM64 config missing: $OUT/.config (run ky42c_xenial_arm64_a0_config.sh first)"

# The first manual Kconfig experiment accidentally generated an in-tree
# .config.  O= builds must not silently depend on or be blocked by stale
# source-tree build state.  Refuse to proceed until it has been cleaned.
if [[ -e "$KERNEL_DIR/.config" || -e "$KERNEL_DIR/include/config/auto.conf" ]]; then
    cat >&2 <<EOF
ERROR: stale in-tree kernel build state detected.

Preserve anything you need, then from the kernel root run:

  cp out-ky42c-arm64-a0/defconfig /tmp/ky42c-arm64-a0.resolved.defconfig
  make mrproper

The generated source target under arch/arm64/configs/ is not removed by
mrproper.  Then rerun the ARM64 config wrapper once to recreate OUT cleanly,
and rerun this DT wrapper.
EOF
    exit 2
fi

MOUNTS=(-v "$WORK_ROOT:$WORK_ROOT")
case "$AARCH64_TC/" in
    "$WORK_ROOT/"*) ;;
    *) MOUNTS+=(-v "$AARCH64_TC:$AARCH64_TC:ro") ;;
esac

note "Building KY-42C ARM64 A0 DTB/DTBO in Ubuntu 16.04"
echo "    WORK_ROOT=$WORK_ROOT"
echo "    KERNEL_DIR=$KERNEL_DIR"
echo "    OUT=$OUT"
echo "    AARCH64_TC=$AARCH64_TC"
echo "    IMAGE=$IMAGE"

docker run --rm -i \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e WORK_ROOT="$WORK_ROOT" \
    -e KERNEL_NAME="$KERNEL_NAME" \
    -e AARCH64_TC="$AARCH64_TC" \
    "${MOUNTS[@]}" \
    -w "$KERNEL_DIR" \
    "$IMAGE" \
    bash -s <<'KY42C_ARM64_DT_INNER'
set -Eeuo pipefail

KERNEL_DIR="$WORK_ROOT/$KERNEL_NAME"
OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
CROSS_COMPILE="$AARCH64_TC/bin/aarch64-linux-android-"
BASE_REL='arch/arm64/boot/dts/mediatek/mt6761.dtb'
OVL_REL='arch/arm64/boot/dts/mediatek/mt6761-FLARE05[0510].dtb'
BASE="$OUT/$BASE_REL"
OVL="$OUT/$OVL_REL"
MERGED="$OVL.merge"
CUST="$OUT/arch/arm64/boot/dts/k61v1_32_bsp_1g/cust.dtsi"
LOG="$OUT/arm64-a0-dt.log"
DUMP="$OUT/arm64-a0-merged.dts"

printf '\nEnvironment:\n'
/usr/bin/python2.7 --version
"${CROSS_COMPILE}gcc" --version | head -n 3
printf 'kernel_git=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"
printf 'config_sha256=%s\n' "$(sha256sum "$OUT/.config" | awk '{print $1}')"

check_exact() {
    local expected="$1"
    grep -Fxq "$expected" "$OUT/.config" || {
        echo "ERROR: required A0 config invariant missing: $expected" >&2
        exit 3
    }
}

check_exact 'CONFIG_ARM64=y'
check_exact 'CONFIG_COMPAT=y'
check_exact 'CONFIG_NR_CPUS=4'
check_exact 'CONFIG_ARCH_MTK_PROJECT="k61v1_32_bsp_1g"'
check_exact 'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="mediatek/mt6761"'
check_exact 'CONFIG_BUILD_ARM64_DTB_OVERLAY_IMAGE_NAMES="mediatek/mt6761-FLARE05[0510]"'
check_exact 'CONFIG_CUSTOM_KERNEL_IMGSENSOR="ov08d10_mipi_raw"'
check_exact 'CONFIG_CUSTOM_KERNEL_LCM="kc_ili9806e_fwvga_dsi_vdo kc_st7701si_fwvga_dsi_vdo"'
check_exact '# CONFIG_TOUCHSCREEN_MTK_GT1151 is not set'
check_exact '# CONFIG_MTK_DUAL_CHARGER_SUPPORT is not set'
check_exact '# CONFIG_CHARGER_RT9465 is not set'

printf '\n==> Build dtbs (includes DrvGen and dtbo_check)\n'
rm -f "$LOG" "$DUMP"
set +e
make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    -j"$(nproc)" \
    dtbs 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if [[ $rc -ne 0 ]]; then
    printf '\nDT build failed (rc=%d). Log preserved at:\n  %s\n' "$rc" "$LOG" >&2
    printf '\nFirst error-like lines:\n' >&2
    grep -nE '(^|[[:space:]])(error:|fatal:|Error|ERROR|No such file|undefined|not found|FATAL)' "$LOG" | head -n 40 >&2 || true
    exit "$rc"
fi

printf '\n==> Required A0 artifacts\n'
for f in "$CUST" "$BASE" "$OVL" "$MERGED" "$OUT/dtbimg.cfg" "$OUT/dtboimg.cfg"; do
    [[ -s "$f" ]] || {
        echo "ERROR: expected DT artifact missing or empty: $f" >&2
        exit 4
    }
    printf '%10d  %s  %s\n' "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')" "$f"
done

DTC="$OUT/scripts/dtc/dtc"
[[ -x "$DTC" ]] || DTC="$KERNEL_DIR/scripts/dtc/dtc"
[[ -x "$DTC" ]] || {
    echo "ERROR: built dtc not found" >&2
    exit 4
}

printf '\n==> Decompile merged A0 tree for semantic checks\n'
"$DTC" -I dtb -O dts -o "$DUMP" "$MERGED"

# Confirm that the product identity applied and the fourth CPU is kept out of
# the first experiment.  Keep these checks deliberately textual and local to
# the merged tree; they are A0 gates, not a general DT linter.
grep -Fq 'board = "MT6761 FLARE05 0510";' "$DUMP" || {
    echo "ERROR: merged DT lacks FLARE05[0510] board identity" >&2
    exit 5
}

cpu3_line="$(grep -n -m1 'cpu@003' "$DUMP" | cut -d: -f1 || true)"
[[ -n "$cpu3_line" ]] || {
    echo "ERROR: merged DT has no cpu@003 node to validate" >&2
    exit 5
}
if ! sed -n "${cpu3_line},$((cpu3_line + 20))p" "$DUMP" | grep -Fq 'status = "disabled";'; then
    echo "ERROR: cpu@003 is not disabled in merged A0 DT" >&2
    exit 5
fi

printf '\nMerged DT highlights:\n'
grep -nE 'model =|compatible = "mediatek,MT6761"|board = "MT6761 FLARE05 0510"|cpu@00[0-3]|status = "disabled"|reserved-memory|kc,keyptr|panel-width|panel-height' "$DUMP" | head -n 120 || true

printf '\nDT image configs:\n'
printf '%s\n' '--- dtbimg.cfg ---'
cat "$OUT/dtbimg.cfg"
printf '%s\n' '--- dtboimg.cfg ---'
cat "$OUT/dtboimg.cfg"

printf '\nARM64_A0_DT_COMPLETE\n'
KY42C_ARM64_DT_INNER
