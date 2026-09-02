#!/usr/bin/env bash
set -Eeuo pipefail

# KY-42C ARM64 A0: resolve the product-correct defconfig inside the same
# Ubuntu 16.04 container used by the boot-validated ARM32 build.
#
# Usage:
#   ./scripts/ky42c/ky42c_xenial_arm64_a0_config.sh \
#       /media/.../working \
#       [kernel-directory-name] \
#       [/absolute/path/to/aosp-aarch64-linux-android-4.9]
#
# Defaults:
#   kernel-directory-name: ky42c-kernel-reconstructed
#   toolchain:             $WORK_ROOT/aosp-aarch64-linux-android-4.9
#   image:                 ky42c-kernel-xenial:16.04-v2
#
# If the toolchain is outside WORK_ROOT, it is bind-mounted read-only at the
# same absolute path.  This preserves the proven v5 container convention: the
# host and container see identical absolute source/toolchain paths.

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

# Reuse the already-qualified image when present.  Rebuild only if explicitly
# requested or if the image does not exist.  The historical v5 wrapper used
# Dockerfile.ky42c-xenial-v2 to create this exact image.
if [[ "${KY42C_REBUILD_IMAGE:-0}" == "1" ]] ||
   ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    DOCKERFILE="${KY42C_DOCKERFILE:-$HOME/Downloads/Dockerfile.ky42c-xenial-v2}"
    [[ -f "$DOCKERFILE" ]] ||
        die "Docker image $IMAGE is missing and Dockerfile not found: $DOCKERFILE"
    BUILD_CTX="$(mktemp -d)"
    trap 'rm -rf "$BUILD_CTX"' EXIT
    cp "$DOCKERFILE" "$BUILD_CTX/Dockerfile"
    note "Building/reusing $IMAGE"
    echo "    Docker context: $BUILD_CTX"
    docker build -f "$BUILD_CTX/Dockerfile" -t "$IMAGE" "$BUILD_CTX"
fi

MOUNTS=(-v "$WORK_ROOT:$WORK_ROOT")
case "$AARCH64_TC/" in
    "$WORK_ROOT/"*) ;;
    *)
        MOUNTS+=(-v "$AARCH64_TC:$AARCH64_TC:ro")
        ;;
esac

note "Resolving KY-42C ARM64 A0 config in Ubuntu 16.04"
echo "    WORK_ROOT=$WORK_ROOT"
echo "    KERNEL_DIR=$KERNEL_DIR"
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
    bash -s <<'KY42C_ARM64_INNER'
set -Eeuo pipefail

KERNEL_DIR="$WORK_ROOT/$KERNEL_NAME"
OUT="$KERNEL_DIR/out-ky42c-arm64-a0"
CROSS_COMPILE="$AARCH64_TC/bin/aarch64-linux-android-"
DEFCONFIG="k61v1_32_bsp_1g_arm64_defconfig"

printf '\nContainer environment:\n'
cat /etc/os-release
printf '\n'
/usr/bin/python2.7 --version

printf '\nAArch64 toolchain:\n'
"${CROSS_COMPILE}gcc" --version | head -n 3
printf 'target=%s\n' "$("${CROSS_COMPILE}gcc" -dumpmachine)"
[[ "$("${CROSS_COMPILE}gcc" -dumpmachine)" == "aarch64-linux-android" ]] || {
    echo "ERROR: unexpected compiler target" >&2
    exit 2
}

for tool in gcc ld as ar nm objcopy objdump strip; do
    test -x "${CROSS_COMPILE}${tool}" || {
        echo "ERROR: missing tool: ${CROSS_COMPILE}${tool}" >&2
        exit 2
    }
done

"${CROSS_COMPILE}ld" --version | head -n 1
"${CROSS_COMPILE}as" --version | head -n 1

LIBGCC="$("${CROSS_COMPILE}gcc" -print-libgcc-file-name)"
test -f "$LIBGCC" || {
    echo "ERROR: GCC reported missing libgcc.a: $LIBGCC" >&2
    exit 2
}
printf 'libgcc=%s\n' "$LIBGCC"
printf 'libgcc_sha256=%s\n' "$(sha256sum "$LIBGCC" | awk '{print $1}')"

CC1="$("${CROSS_COMPILE}gcc" -print-prog-name=cc1)"
printf 'cc1=%s\n' "$CC1"
if [[ -f "$CC1" ]]; then
    CC1_DEPS="$(ldd "$CC1" 2>&1)"
    printf '%s\n' "$CC1_DEPS" | grep -E 'mpfr|mpc|gmp|not found' || true
    if grep -q 'not found' <<<"$CC1_DEPS"; then
        echo "ERROR: AArch64 compiler has unresolved Xenial host dependencies" >&2
        exit 2
    fi
fi

if git -C "$AARCH64_TC" rev-parse HEAD >/dev/null 2>&1; then
    printf 'toolchain_git=%s\n' "$(git -C "$AARCH64_TC" rev-parse HEAD)"
fi
printf 'kernel_git=%s\n' "$(git -C "$KERNEL_DIR" rev-parse HEAD)"

printf '\n==> Fresh ARM64 output tree\n'
rm -rf "$OUT"
mkdir -p "$OUT"

printf '\n==> Generate the product-correct ARM64 source defconfig\n'
/usr/bin/python2.7 "$KERNEL_DIR/scripts/ky42c/prepare_arm64_a0_defconfig.py"

printf '\n==> Resolve defconfig through ARM64 Kconfig\n'
make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    "$DEFCONFIG"

make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    olddefconfig

make -C "$KERNEL_DIR" \
    O="$OUT" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    python=/usr/bin/python2.7 \
    savedefconfig

cp "$OUT/defconfig" "$OUT/k61v1_32_bsp_1g_arm64.resolved.defconfig"

printf '\n==> A0 config invariants\n'
grep -E \
'^(CONFIG_ARM64=|CONFIG_COMPAT=|CONFIG_NR_CPUS=|CONFIG_ARCH_MTK_PROJECT=|CONFIG_BUILD_ARM64_|CONFIG_CUSTOM_KERNEL_LCM=|CONFIG_CUSTOM_KERNEL_IMGSENSOR=|CONFIG_MTK_MUSB_DRV_36BIT=|CONFIG_TOUCHSCREEN_MTK=|# CONFIG_TOUCHSCREEN_MTK is not set|CONFIG_TOUCHSCREEN_MTK_GT1151=|# CONFIG_TOUCHSCREEN_MTK_GT1151 is not set|CONFIG_MTK_DUAL_CHARGER_SUPPORT=|# CONFIG_MTK_DUAL_CHARGER_SUPPORT is not set|CONFIG_CHARGER_RT9465=|# CONFIG_CHARGER_RT9465 is not set|CONFIG_TOUCHSCREEN_MTK_PARADE=)' \
    "$OUT/.config" || true

# Hard failures are limited to reference-board settings that contradict the KY
# product configuration.  PARADE/CYTTSP5 is intentionally NOT rejected here:
# the shipping KY ARM32 resolved config also gets that Kyocera subtree through
# its default-y Kconfig, despite the handset having no physical touchscreen.
check_exact() {
    local expected="$1"
    grep -Fxq "$expected" "$OUT/.config" || {
        echo "ERROR: required config invariant missing: $expected" >&2
        exit 3
    }
}

check_exact 'CONFIG_ARM64=y'
check_exact 'CONFIG_COMPAT=y'
check_exact 'CONFIG_NR_CPUS=4'
check_exact 'CONFIG_ARCH_MTK_PROJECT="k61v1_32_bsp_1g"'
check_exact 'CONFIG_CUSTOM_KERNEL_IMGSENSOR="ov08d10_mipi_raw"'
check_exact 'CONFIG_CUSTOM_KERNEL_LCM="kc_ili9806e_fwvga_dsi_vdo kc_st7701si_fwvga_dsi_vdo"'
check_exact '# CONFIG_TOUCHSCREEN_MTK is not set'
check_exact '# CONFIG_TOUCHSCREEN_MTK_GT1151 is not set'
check_exact '# CONFIG_MTK_DUAL_CHARGER_SUPPORT is not set'
check_exact '# CONFIG_CHARGER_RT9465 is not set'

printf '\nResolved artifacts:\n'
printf '  %s\n' "$OUT/.config"
printf '  %s\n' "$OUT/defconfig"
printf '  %s\n' "$OUT/k61v1_32_bsp_1g_arm64.resolved.defconfig"
printf '  .config sha256=%s\n' "$(sha256sum "$OUT/.config" | awk '{print $1}')"
printf '  defconfig sha256=%s\n' "$(sha256sum "$OUT/defconfig" | awk '{print $1}')"

if grep -Fxq 'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y' "$OUT/.config"; then
    printf '\nNOTE: MediaTek Kconfig therefore chooses Image.gz-dtb as the default KBUILD_IMAGE.\n'
    printf '      A0 packaging will still build/select arch/arm64/boot/Image.gz explicitly;\n'
    printf '      the appended-DTB setting is retained for MediaTek DT build plumbing.\n'
fi

printf '\nARM64_A0_CONFIG_COMPLETE\n'
KY42C_ARM64_INNER
