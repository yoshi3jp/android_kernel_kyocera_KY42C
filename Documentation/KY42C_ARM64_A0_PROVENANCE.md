# KY-42C ARM64 A0 portability provenance

Status: post-A0 compile audit, 2026-09-03

This note records why each source change made after the first successful
AArch64 A0 build is justified. The purpose is to avoid treating every GCC
warning as an ad-hoc porting task. For each A0 blocker, first identify whether
it came from upstream Linux, common MediaTek BSP history, older Kyocera product
code, or the KY-42C-specific product layer, then use the closest authoritative
solution.

The first complete A0 build was produced at feature-branch commit
`6f069a6c5a3a7b70d9dce73c55d4492a358cf1db`. It yielded a valid AArch64
`vmlinux`, `Image`, `Image.gz`, base DTB, FLARE05[0510] DTBO and merged tree.
The temporary `-Wno-error` additions on that branch were compile-audit
scaffolding only and are not part of the intended stabilized port.

## Provenance rule

Use the following order of authority:

1. Generic ARM64/core defect: use upstream Linux or Android common history.
2. MediaTek subsystem: use same-generation MT6761 ARM64 first, then MT6765 or
   another closely related ALPS 4.9 ARM64 branch.
3. Kyocera code shared across products: preserve the product behavior and make
   the code architecture-width neutral; do not invent an MTK implementation
   for a Kyocera peripheral driver.
4. KY-42C/sibling-only subdisplay: treat as product code. Preserve control
   flow and hardware semantics and repair only demonstrated width assumptions.

The synthetic reconstruction commits are evidence boundaries, not claims
about the exact dates or commit boundaries in Kyocera's private repository.
Where a reconstructed path has real pre-KY history, that ancestry is stronger
than the synthetic grouping. Where no same-path witness exists, compare the
Kyocera OSS generations and sibling/supplier trees instead.

## 1. ARM64 dcache macro: upstream Linux defect

A0 `nm -u vmlinux` reported strong undefined symbols `civac`, `cvac`, and
`cvau`. The current 4.9 ARM64 `dcache_by_line_op` macro compares operation
names as assembler symbols:

```asm
.if (\op == cvau || \op == cvac)
```

Upstream Linux commit `33309ecda0070506c49182530abe7728850ebe78`
(`arm64: Fix minor issues with the dcache_by_line_op macro`) documents exactly
this failure mode and changes the comparisons to GAS string conditionals
(`.ifc`).

The upstream commit also contains later DC CVAP/DCPOP handling that this 4.9
tree does not have. Therefore the KY-42C cleanup takes only the compatible
part: use `.ifc` for the existing `cvau` and `cvac` cases while preserving the
existing `ARM64_WORKAROUND_CLEAN_CACHE` behavior. Do not introduce DCPOP as
part of this backport.

Classification: **upstream ARM64 fix**.

## 2. mtk_charger factory sysfs stores: KY branch addition inside MTK code

The five A0 failures are `size_t size` values printed with `%d` in the
Kyocera factory/custom sysfs store handlers:

- `store_is_factory_use`
- `store_sdp_charging_current`
- `store_full_charging_capacity`
- `store_vbat_limitation`
- `store_fact_chg_time`

The file has genuine MediaTek ancestry, but the reconstructed divergence commit
`87c0819eaac1d9fc5cdb7e5a70ba809c83db3150` adds this exact block. A public
same-generation MT6761 4.9 reference,
`mediatek-android-development/android_kernel_mediatek_mt6761-62-4.9`, does not
contain these handlers. Public code search for `show_is_factory_use` finds the
KY-42C family copies rather than the generic MTK implementation.

This is therefore not an MT6761 ARM64 algorithm that needs transplanting. The
correct architecture-neutral kernel form is simply `%zu` for `size_t`.

Classification: **KY product extension in an MTK file; width-neutral fix**.

## 3. DRV2604 vibrator: long-lived Kyocera driver baggage

The A0 failures are diagnostic pointer casts such as:

```c
VIB_DEBUG_LOG(..., "called. work=0x%08x\n", (unsigned int)work);
```

The reconstructed path enters through product integration commit
`4d348e177c389b099df3b702805f8844321da32b`, with no exact Motorola same-path
witness. However this is not a KY-42C-only 32-bit rewrite: the same
`drv2604-vibrator.c` family and the same pointer-as-`unsigned int` logging style
are present in older Kyocera trees, including the public BALMUDA source and
other Kyocera products.

The driver already uses the real pointer types in its data path. Only the
logs narrow them. Replace the logging format with `%p` and pass the pointer
without an integer cast. No `CONFIG_ARM64` branch is required.

Classification: **shared Kyocera driver; architecture-width-neutral logging
fix**.

## 4. LP5569 and LV5216 LEDs: shared Kyocera driver style

The A0 blockers cast `&client->dev` to `unsigned int` only for two probe error
messages in each driver. The same forms are visible in the KYF42 public
Kyocera sources (`leds-lp5569kc.c` and `leds-lv5216kc.c`), so these are not
MT6761-specific defects and not evidence of a KY-42C-only ARM32 conversion.

Use `%p` and pass `&client->dev` directly. Preserve all LED programming and
probe behavior.

Classification: **shared Kyocera driver; architecture-width-neutral logging
fix**.

## 5. KY subdisplay: product-special treatment

The subdisplay sources enter the reconstructed history through
`b0dbe523f2f197f14892f57f1951d55323c33fad`, the KY product display/subdisplay
integration group, with no exact same-path Motorola witness. This hardware is
specific to KY-42C or its close sibling, so a generic MT6761 display tree is
not an authoritative behavioral replacement.

A0 exposed only diagnostic-width problems in the failing sites. The actual
functional variables already use appropriate types (`size_t`, `dma_addr_t`,
normal pointers), including the coherent framebuffer allocation. The cleanup
therefore does only the following:

- pointer diagnostics: `%x`/`%d` plus `(int)`/`(unsigned int)` -> `%p` plus the
  original pointer;
- framebuffer size: `%d` -> `%zu`;
- DMA address: `%08x` -> `%pad` and pass `&phys` as required by kernel printk.

Do not change framebuffer size calculations, the number of buffers, panel
state transitions, image conversion, ST7571/LD7032 sequencing, regulator/GPIO
handling, or bus transactions merely to make the port look more generic.

Classification: **KY-specific product code; minimal type-correct cleanup**.

## 6. Printk type conventions

The Linux 4.9 tree itself documents and uses the formats required here:

- kernel pointer: `%p`;
- `size_t`: `%zu` (or `%zx` when hexadecimal is actually desired);
- `dma_addr_t`: `%pad`, with a pointer to the `dma_addr_t` value.

The existing tree contains many `%pad` examples, including DMA engine code, so
this does not require a newer printk extension.

## Cleanup gate

`scripts/ky42c/prepare_arm64_a0_cleanup.py` encodes the above changes with
expected occurrence counts and refuses unexpected source drift. After it is
applied, the next build gate is:

```text
- no A0 -Wno-error waiver remains
- no hard pointer-width/size_t/DMA format warning in the audited files
- nm -u vmlinux no longer contains civac/cvac/cvau
- ARM64_A0_KERNEL_BUILD_COMPLETE still reached
- DT artifacts remain byte-identical, since this cleanup does not touch DT
```

Only after that gate should this cleanup be treated as the first boot-candidate
source baseline.
