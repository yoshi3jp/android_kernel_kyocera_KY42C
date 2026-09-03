# KY-42C ARM64 A1: TWRP recovery boot experiment

## Objective

A1 is not an Android-system boot test.  It is the first hardware proof that the
shipping KY-42C LK/BL31 path can enter the clean AArch64 Linux 4.9 kernel and
that the core kernel can progress far enough to support the already-working
TWRP recovery environment.

The test deliberately preserves the validated 32-bit TWRP userspace.  The
kernel is AArch64 and supplies `CONFIG_COMPAT=y`; the recovery binaries remain
ARMv7.  This separates AArch64 kernel entry from Android-system and vendor
userspace problems.

## Why recovery is the first hardware target

The existing KY-42C TWRP tree is hardware validated for display, ADB, dynamic
partitions, keypad/pointer handling and user-0 FBE work.  Testing A1 as recovery
therefore gives a known userspace and leaves the normal Android boot partition
unchanged.  If the recovery candidate fails, ordinary Android remains the
primary way back to adb/fastboot and to restore a known-good recovery image.

No preloader, LK, modem, TEE or normal boot image modification is part of A1.

## A1 boot-image composition

The existing TWRP device tree uses Android boot header version 2, 2048-byte
pages, a forced prebuilt kernel, a separate DTB field and a recovery-DTBO
section.  A1 keeps that topology.

The three prebuilt replacements are:

```
prebuilt/kernel
    ARM64 arch/arm64/boot/Image.gz

prebuilt/dtb.img
    ARM64 arch/arm64/boot/dts/mediatek/mt6761.dtb

prebuilt/dtbo.img
    Android DTBO image containing the ARM64
    mt6761-FLARE05[0510].dtb overlay
```

The TWRP ramdisk, command line, offsets, page size, recovery AVB settings and
32-bit recovery userspace remain unchanged.

### No ARM32 appended kernel DTB

Stock ARM32 boot/recovery packaging historically contains an appended kernel
DTB in addition to the header-v2 DTB.  That was correct for the ARM32 zImage
path and MagiskBoot could split it as `kernel_dtb`.

The ARM64 A1 design does **not** carry that ARM32 appended DTB forward.  The
AArch64 kernel payload is `Image.gz`; its hardware description is supplied by
the separate header-v2 ARM64 base DTB and the ARM64 recovery DTBO.  Reusing the
old appended ARM32 DTB would mix two architecture-specific DT descriptions and
would make an early failure ambiguous.

This is also why the preferred A1 construction method is a fresh TWRP source
build from the staged ARM64 prebuilts rather than taking an old recovery image,
unpacking it and accidentally letting an old `kernel_dtb` survive repacking.

## Device-tree model

A0 intentionally compiled only the known runtime board revision,
FLARE05[0510].  The ARM64 base DTB describes MT6761 architecture; the recovery
DTBO carries the KY product/revision layer.  The A0 overlay-check merged DTB is
retained as a validation artifact but is not directly substituted for the
normal base-DTB-plus-DTBO packaging model.

The validated merged tree has:

- board identity `MT6761 FLARE05 0510`;
- CPU0-CPU2 enabled and CPU3 disabled;
- the KY keypad/product nodes;
- the KY subdisplay description;
- the ARM64 MT6761 memory and reserved-memory architecture.

For this single-entry recovery DTBO, FLARE05[0510] becomes entry index 0.  The
purpose is a controlled known-hardware A1 experiment, not a production image
for all KY-42C board revisions.  The full stock overlay set can be restored
after AArch64 entry is established.

## Staging helper

From the A1 kernel branch:

```
./scripts/ky42c/ky42c_arm64_a1_twrp_stage.sh \
    /path/to/android_device_kyocera_KY-42C \
    /path/to/mkdtimg
```

The default mode is non-mutating.  It validates the clean A0 artifacts,
preserves hashes of the current TWRP prebuilts and creates:

```
out-ky42c-arm64-a1-twrp/
    stock-prebuilt/
    a1-prebuilt/
        kernel
        dtb.img
        dtbo.img
    manifest.txt
    README.txt
```

After reviewing the manifest, install the staged prebuilts with:

```
./scripts/ky42c/ky42c_arm64_a1_twrp_stage.sh \
    /path/to/android_device_kyocera_KY-42C \
    /path/to/mkdtimg \
    --install
```

Then build TWRP recovery normally from its existing `twrp-12.1` environment.
Do not change `TARGET_ARCH := arm`; that describes the recovery userspace,
which is intentionally still 32-bit.

## Pre-hardware verification

Before writing the recovery partition, record at minimum:

```
git -C kernel rev-parse HEAD
git -C device/kyocera/KY-42C rev-parse HEAD
sha256sum recovery.img
sha256sum out-ky42c-arm64-a1-twrp/a1-prebuilt/*
```

If MagiskBoot is available, unpack the newly built recovery image into a fresh
directory and verify:

- header version remains 2;
- kernel format is gzip;
- decompressed kernel has ARM64 `ARMd` Image magic;
- there is no inherited ARM32 `kernel_dtb` appended to the kernel;
- the separate `dtb` equals the staged ARM64 base DTB;
- the recovery-DTBO section is present;
- ramdisk and unrelated recovery geometry remain the TWRP values.

The final image must fit the 32 MiB recovery partition.

## Hardware test boundary

A1 should modify only `recovery`.  Do not replace `boot` for this experiment.
Keep both a known-good TWRP recovery image and the normal Android boot image on
the host.

Use the same already-proven method by which TWRP recovery images have been
installed on this handset.  A1 does not establish a new flashing path.

Immediately after attempting recovery boot, classify the result by the
furthest observable stage:

1. LK rejects/never hands off: packaging or LK AArch64 handoff problem.
2. Immediate reset after handoff: very-early ARM64/DT/memory failure.
3. Persistent kernel/AEE/pstore evidence: AArch64 entry proven; debug core
   architecture from the first fault.
4. ADB appears but TWRP UI does not: A1 core entry is already largely proven;
   move diagnosis toward framebuffer/input/recovery services.
5. TWRP menu appears: A1 entry/core plus a substantial portion of A2 are
   effectively reached; capture evidence before enabling additional hardware.

## First evidence to collect after any successful shell

```
uname -a
uname -m
cat /proc/cmdline
cat /proc/cpuinfo
cat /proc/meminfo
cat /proc/interrupts | head -n 80
cat /sys/devices/system/cpu/online
cat /sys/devices/system/cpu/present
cat /sys/devices/system/cpu/possible
dmesg > /tmp/ky42c-a1-dmesg.txt
```

Expected architectural identity is `aarch64`, with the recovery userspace
remaining 32-bit.  CPU topology should remain the product-controlled three
online CPUs for the first experiment.

If the boot fails before a shell, collect any available AEE/pstore/ramoops and
boot-reason evidence after returning to Android.  Do not begin changing display,
modem, Android init or vendor userspace until basic AArch64 entry, timer/GIC and
memory behavior are understood.
