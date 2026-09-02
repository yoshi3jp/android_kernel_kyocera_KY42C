# KY-42C ARM64 A0 implementation decisions

This note records the source-level decisions for the first AArch64 Linux 4.9
bring-up target.  It is intentionally narrower than the long-term GKI plan.

## Product truth vs architecture truth

* Product/peripheral policy comes from
  `arch/arm/configs/k61v1_32_bsp_1g_defconfig` and the KY FLARE DT sources.
* AArch64 architecture requirements come from the same-tree MT6761 ARM64
  target, especially `arch/arm64/configs/k61v1_64_bsp_defconfig` and
  `arch/arm64/boot/dts/mediatek/mt6761.dts`.
* `CONFIG_ARCH_MTK_PROJECT="k61v1_32_bsp_1g"` is preserved.  The project
  string is consumed by DrvGen and product-specific MediaTek driver plumbing;
  it is not an ISA selector.

## Important source inspection result: no separate project DTS is required for A0

The first planning draft proposed adding an ARM64 copy of
`k61v1_32_bsp_1g.dts`.  Inspection of the actual DT build path showed that
this is not necessary for the first FLARE test.

The shipping KY defconfig builds a generic MT6761 base DTB plus FLARE DTBOs.
`scripts/drvgen/drvgen.mk` obtains the project names from the configured DTBO
list and scans each overlay DTS for an include of `<project/cust.dtsi>`.  That
include selects the DWS and causes DrvGen to emit the generated project
`cust.dtsi` under the architecture-specific object tree.

For ARM64 A0 the intended topology is therefore:

```
ARM64 base DTB:
  arch/arm64/boot/dts/mediatek/mt6761.dts

A0 DTBO:
  arch/arm64/boot/dts/mediatek/mt6761-FLARE05[0510].dts
       -> shared shipping FLARE common/product fragments
       -> <k61v1_32_bsp_1g/cust.dtsi>

DWS input:
  drivers/misc/mediatek/dws/mt6761/k61v1_32_bsp_1g.dws
```

This keeps the shipping FLARE files as a single product source of truth while
we prove the ISA transition.  Once ARM64 boot is stable, the DT sources can be
reorganized into a shared architecture-neutral location if desired.

## A0 DT scope

Only the live-tested `FLARE05[0510]` board revision is enabled initially.
The full shipping overlay set is restored after the ARM64 baseline boots.
The ARM64 MT6761 base contains all four physical Cortex-A53 CPUs; the A0
wrapper marks CPU3 disabled so the experiment preserves the shipping
three-CPU product topology.  Enabling the fourth core is a separate test.

## Initial defconfig transformation

`scripts/ky42c/prepare_arm64_a0_defconfig.py` derives the initial ARM64
configuration from the shipping KY ARM32 defconfig.  It deliberately does not
start from the generic ARM64 reference configuration.

Architecture changes made before Kconfig resolution:

* AArch64 cross-compile prefix placeholder.
* remove ARM32-only HIGHMEM/PSCI/ARM module/unwind choices;
* use ARM64 DTB/DTBO configuration names;
* enable `CONFIG_COMPAT` for the stock AArch32 Android 10 userspace;
* set `CONFIG_NR_CPUS=4` while the DT keeps CPU3 disabled;
* enable KASLR and the ARM64 crypto selections present in the same-tree MT6761
  reference target;
* enable the MT6761 ARM64 reference's 36-bit MUSB path.

The generator explicitly checks that KY product selections remain present:
OV08D10 camera, 854x480 Kyocera LCMs, no MTK/GT1151 touchscreen, no generic
dual charger/RT9465, and Kyocera USB/product options.

The generated defconfig is **not yet final**.  It must be run through the
4.9 Kconfig implementation in the Xenial build environment, followed by
`savedefconfig`, before being committed as the stable target.

## Required next validation

Inside the established Xenial environment with the qualified AOSP
`aarch64-linux-android-4.9` toolchain:

```
python scripts/ky42c/prepare_arm64_a0_defconfig.py

make O="$OUT" ARCH=arm64 \
  CROSS_COMPILE="$AARCH64_PREFIX" \
  k61v1_32_bsp_1g_arm64_defconfig

make O="$OUT" ARCH=arm64 \
  CROSS_COMPILE="$AARCH64_PREFIX" \
  olddefconfig

make O="$OUT" ARCH=arm64 \
  CROSS_COMPILE="$AARCH64_PREFIX" \
  savedefconfig
```

Before replacing the source defconfig with the resolved `defconfig`, compare
`$OUT/.config` against both the KY ARM32 product configuration and the generic
MT6761 ARM64 reference.  Any newly enabled foreign peripheral is a config
regression until proven otherwise.

Then build the base DTB and the single A0 DTBO.  The first expected failures
should be treated as evidence: fix only code actually selected by the
product-correct ARM64 configuration.

## Stop condition before first flash

Do not construct the first ARM64 boot image until all of the following are
true:

* the generated configuration resolves cleanly under ARM64 Kconfig;
* `CONFIG_ARCH_MTK_PROJECT` remains `k61v1_32_bsp_1g`;
* the DWS/DrvGen path produces the expected ARM64-object-tree `cust.dtsi`;
* `mediatek/mt6761.dtb` and `mediatek/mt6761-FLARE05[0510].dtb` compile;
* the effective configuration contains no generic touchscreen, RT9465, dual
  charger, reference camera or reference LCM selections;
* CPU3 is disabled for A0;
* the effective reserved-memory map has been reviewed;
* the known-good stock boot image and preloader boot-partition restore path are
  ready.
