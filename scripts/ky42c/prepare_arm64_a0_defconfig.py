#!/usr/bin/env python
"""Generate the first KY-42C ARM64 Linux 4.9 defconfig.

Compatible with the Xenial-era Python used by the MediaTek build environment.

The shipping ARM32 defconfig is the product source of truth.  This tool makes
only the narrow architecture/package substitutions required to construct the
A0 ARM64 target, instead of starting from the generic k61v1_64_bsp reference
configuration and trying to remove unrelated reference-board hardware.

The generated file is intended to be resolved once through Kconfig in the
Xenial build container (olddefconfig/savedefconfig) before it is treated as a
stable committed defconfig.
"""

from __future__ import print_function

import argparse
import io
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_IN = os.path.join(ROOT, "arch", "arm", "configs",
                          "k61v1_32_bsp_1g_defconfig")
DEFAULT_OUT = os.path.join(ROOT, "arch", "arm64", "configs",
                           "k61v1_32_bsp_1g_arm64_defconfig")

# ARM32-only choices that must not be copied into an ARM64 defconfig.
DROP_SYMBOLS = {
    "CONFIG_HAVE_ARM_ARCH_TIMER",
    "CONFIG_ARM_PSCI",
    "CONFIG_HIGHMEM",
    "CONFIG_HIGHPTE",
    "CONFIG_ARM_MODULE_PLTS",
    "CONFIG_ARM_UNWIND",
    "CONFIG_BUILD_ARM_APPENDED_DTB_IMAGE",
    "CONFIG_BUILD_ARM_APPENDED_DTB_IMAGE_NAMES",
    "CONFIG_BUILD_ARM_DTB_OVERLAY_IMAGE_NAMES",
}


def symbol_of(line):
    m = re.match(r"(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=| is not set)", line)
    return m.group(1) if m else None


def transform(lines):
    out = []
    inserted_arch = False
    inserted_musb = False

    for raw in lines:
        line = raw.rstrip("\n")
        sym = symbol_of(line)

        if sym in DROP_SYMBOLS:
            continue

        if sym == "CONFIG_CROSS_COMPILE":
            out.append('CONFIG_CROSS_COMPILE="aarch64-linux-android-"')
            continue

        # The ARM64 MT6761 sibling uses NR_CPUS=8.  KY-42C is a four-core
        # physical SoC and ships with three CPUs described; cap the compile
        # time maximum at four and keep CPU3 disabled in the A0 overlay.
        if sym == "CONFIG_MACH_MT6761":
            out.append(line)
            out.append("CONFIG_NR_CPUS=4")
            continue

        if sym == "CONFIG_ZSMALLOC":
            out.append(line)
            if not inserted_arch:
                out.extend([
                    "# CONFIG_BOUNCE is not set",
                    "CONFIG_RANDOMIZE_BASE=y",
                    "# CONFIG_EFI is not set",
                    "CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y",
                    'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="mediatek/mt6761"',
                    'CONFIG_BUILD_ARM64_DTB_OVERLAY_IMAGE_NAMES="mediatek/mt6761-FLARE05[0510]"',
                    "CONFIG_COMPAT=y",
                ])
                inserted_arch = True
            continue

        # The MT6761 ARM64 reference enables the 36-bit MUSB DMA path.  This
        # is architecture/platform plumbing, not reference-board peripheral
        # policy, so carry it into the KY target.
        if sym == "CONFIG_MTK_MUSB_QMU_PURE_ZLP_SUPPORT":
            out.append(line)
            out.append("CONFIG_MTK_MUSB_DRV_36BIT=y")
            inserted_musb = True
            continue

        out.append(line)

    if not inserted_arch:
        raise RuntimeError("could not locate CONFIG_ZSMALLOC insertion point")
    if not inserted_musb:
        raise RuntimeError("could not locate MTK MUSB insertion point")

    # AArch64 accelerated crypto choices present in the same-tree MT6761
    # reference target.  These do not alter KY peripheral selection.
    out.extend([
        "CONFIG_ARM64_CRYPTO=y",
        "CONFIG_CRYPTO_SHA2_ARM64_CE=y",
        "CONFIG_CRYPTO_AES_ARM64_CE_BLK=y",
    ])

    return out


def validate(text):
    required = [
        'CONFIG_ARCH_MTK_PROJECT="k61v1_32_bsp_1g"',
        'CONFIG_MTK_PLATFORM="mt6761"',
        "CONFIG_COMPAT=y",
        "CONFIG_NR_CPUS=4",
        'CONFIG_CUSTOM_KERNEL_IMGSENSOR="ov08d10_mipi_raw"',
        'CONFIG_CUSTOM_KERNEL_LCM="kc_ili9806e_fwvga_dsi_vdo kc_st7701si_fwvga_dsi_vdo"',
        'CONFIG_LCM_HEIGHT="854"',
        'CONFIG_LCM_WIDTH="480"',
        "# CONFIG_TOUCHSCREEN_MTK is not set",
        "# CONFIG_MTK_DUAL_CHARGER_SUPPORT is not set",
        "CONFIG_KC_USB_CDROM=y",
        "CONFIG_KC_PC9359=y",
        'CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES="mediatek/mt6761"',
        'CONFIG_BUILD_ARM64_DTB_OVERLAY_IMAGE_NAMES="mediatek/mt6761-FLARE05[0510]"',
    ]
    forbidden = [
        "CONFIG_TOUCHSCREEN_MTK=y",
        "CONFIG_TOUCHSCREEN_MTK_GT1151=y",
        "CONFIG_MTK_DUAL_CHARGER_SUPPORT=y",
        "CONFIG_CHARGER_RT9465=y",
        'CONFIG_CUSTOM_KERNEL_LCM="nt35521_hd_dsi_vdo_truly_rt5081"',
        'CONFIG_ARCH_MTK_PROJECT="k61v1_64_bsp"',
        "CONFIG_HIGHMEM=y",
        "CONFIG_ARM_PSCI=y",
    ]

    # Validate complete config records, not arbitrary substrings.  The KY
    # shipping defconfig intentionally retains commented historical/reference
    # lines such as:
    #   # CONFIG_TOUCHSCREEN_MTK_GT1151=y
    #   # CONFIG_CUSTOM_KERNEL_LCM="nt35521_hd_dsi_vdo_truly_rt5081"
    # Those are comments documenting removed reference-board choices and must
    # not be mistaken for active Kconfig settings.
    records = set(line.rstrip() for line in text.splitlines())

    missing = [x for x in required if x not in records]
    bad = [x for x in forbidden if x in records]
    if missing or bad:
        if missing:
            print("Missing required A0 choices:", file=sys.stderr)
            for item in missing:
                print("  " + item, file=sys.stderr)
        if bad:
            print("Foreign/ARM32 choices still present:", file=sys.stderr)
            for item in bad:
                print("  " + item, file=sys.stderr)
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=DEFAULT_IN)
    ap.add_argument("--output", default=DEFAULT_OUT)
    ap.add_argument("--check", action="store_true",
                    help="validate an already-generated output and exit")
    args = ap.parse_args()

    if args.check:
        with io.open(args.output, "r", encoding="utf-8") as f:
            text = f.read()
        return 0 if validate(text) else 1

    with io.open(args.input, "r", encoding="utf-8") as f:
        lines = f.readlines()

    generated = "\n".join(transform(lines)) + "\n"
    if not validate(generated):
        return 1

    parent = os.path.dirname(args.output)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    with io.open(args.output, "w", encoding="utf-8") as f:
        f.write(generated)

    print("Wrote %s" % args.output)
    print("Next: resolve it in Xenial with ARCH=arm64 olddefconfig, then savedefconfig.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
