#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# KY-42C ARM64 A0 provenance-guided cleanup.
#
# The A0 compile-audit deliberately used narrow -Wno-error waivers so the
# first complete AArch64 build could expose the whole portability surface.
# This tool removes those waivers and applies only the source changes whose
# provenance and type semantics are now understood.
#
# Usage:
#   scripts/ky42c/prepare_arm64_a0_cleanup.py --check
#   scripts/ky42c/prepare_arm64_a0_cleanup.py --apply
#
# It intentionally does not change device behavior, register programming,
# framebuffer geometry, DMA allocation, panel sequencing, or GPIO/SPI/I2C
# control flow.

from __future__ import print_function

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CleanupError(RuntimeError):
    pass


def read(path):
    p = ROOT / path
    try:
        return p.read_text()
    except OSError as exc:
        raise CleanupError("%s: %s" % (path, exc))


def replace_expected(text, old, new, expected, path, label):
    """Exact replacement with source-shape validation and idempotence."""
    old_count = text.count(old)
    new_count = text.count(new)

    if old_count == expected:
        return text.replace(old, new), expected

    # A second --check/--apply after cleanup should be harmless.
    if old_count == 0 and new_count >= expected:
        return text, 0

    raise CleanupError(
        "%s: %s: expected %d old occurrence(s), found %d "
        "(new form count=%d)" %
        (path, label, expected, old_count, new_count))


def apply_replacements(path, replacements):
    text = read(path)
    original = text
    total = 0
    for label, old, new, expected in replacements:
        text, n = replace_expected(text, old, new, expected, path, label)
        total += n
    return path, original, text, total


def fix_arm64_dcache():
    path = "arch/arm64/include/asm/assembler.h"
    old = r'''9998:
	.if	(\op == cvau || \op == cvac)
alternative_if_not ARM64_WORKAROUND_CLEAN_CACHE
	dc	\op, \kaddr
alternative_else
	dc	civac, \kaddr
alternative_endif
	.else
	dc	\op, \kaddr
	.endif
'''
    new = r'''9998:
	.ifc	\op, cvau
alternative_if_not ARM64_WORKAROUND_CLEAN_CACHE
	dc	\op, \kaddr
alternative_else
	dc	civac, \kaddr
alternative_endif
	.else
	.ifc	\op, cvac
alternative_if_not ARM64_WORKAROUND_CLEAN_CACHE
	dc	\op, \kaddr
alternative_else
	dc	civac, \kaddr
alternative_endif
	.else
	dc	\op, \kaddr
	.endif
	.endif
'''
    return apply_replacements(path, [
        ("upstream dcache_by_line_op string comparison", old, new, 1),
    ])


def fix_drv2604():
    path = "drivers/misc/drv2604-vibrator.c"
    repl = [
        ("i2c client/buffer format",
         "client=0x%08x,buf=0x%08x\\n",
         "client=%p,buf=%p\\n", 1),
        ("i2c client format",
         "client=0x%08x\\n",
         "client=%p\\n", 1),
        ("work pointer format",
         "called. work=0x%08x\\n",
         "called. work=%p\\n", 3),
        ("work_data pointer format",
         "work_data=0x%08x,time=%d\\n",
         "work_data=%p,time=%d\\n", 1),
        ("timed-on device pointer format",
         "called. dev=0x%08x, timeout_val=%d\\n",
         "called. dev=%p, timeout_val=%d\\n", 1),
        ("device pointer format",
         "called. dev=0x%08x\\n",
         "called. dev=%p\\n", 3),
        ("enable device pointer format",
         "called. dev=0x%08x,value=%d\\n",
         "called. dev=%p,value=%d\\n", 1),
        ("timer pointer format",
         "called. timer=0x%08x\\n",
         "called. timer=%p\\n", 2),
        ("i2c id pointer format",
         "called. id=0x%08x\\n",
         "called. id=%p\\n", 1),
        ("client pointer cast", "(unsigned int)client", "client", 2),
        ("buffer pointer cast", "(unsigned int)buf", "buf", 1),
        ("work pointer cast", "(unsigned int)work", "work", 3),
        ("work_data pointer cast",
         "(unsigned int)work_data", "work_data", 1),
        ("timed-output device pointer cast",
         "(unsigned int)dev", "dev", 5),
        ("timer pointer cast", "(unsigned int)timer", "timer", 2),
        ("i2c id pointer cast", "(unsigned int)id", "id", 1),
    ]
    return apply_replacements(path, repl)


def fix_charger():
    path = "drivers/power/supply/mediatek/charger/mtk_charger.c"
    return apply_replacements(path, [
        ("Kyocera factory sysfs size_t logging",
         "size is %d\\n", "size is %zu\\n", 5),
    ])


def fix_led(path, prefix):
    return apply_replacements(path, [
        (prefix + " device-pointer format",
         "Dev=[0x%08x]", "Dev=[%p]", 2),
        (prefix + " device-pointer cast",
         "(unsigned int)&client->dev", "&client->dev", 2),
    ])


def fix_subdisplay_ctrl():
    path = ("drivers/misc/mediatek/video/mt6765/videox/kyocera/"
            "disp_ext_sub_ctrl.c")
    return apply_replacements(path, [
        ("framebuffer pointer parameter formats",
         "var[%x] info[%x]", "var[%p] info[%p]", 2),
        ("fb_var pointer casts", "(unsigned int)var", "var", 2),
        ("fb_info pointer casts", "(unsigned int)info", "info", 2),
        ("framebuffer size/DMA formats",
         "size=%d vir_addr=%p phys_addr=%08x",
         "size=%zu vir_addr=%p phys_addr=%pad", 1),
        ("dma_addr_t argument by address",
         "__func__, size, virt, phys);",
         "__func__, size, virt, &phys);", 1),
    ])


def fix_subdisplay_dbg():
    path = ("drivers/misc/mediatek/video/mt6765/videox/kyocera/"
            "disp_ext_sub_dbg.c")
    return apply_replacements(path, [
        ("sequence buffer pointer format",
         "buf_p:[%x],blen:[%d],cmd_cnt:[%d]",
         "buf_p:[%p],blen:[%d],cmd_cnt:[%d]", 1),
        ("sequence buffer pointer cast",
         "(int)cmd_p->buf_p", "cmd_p->buf_p", 1),
    ])


def fix_subdisplay_st7571():
    path = ("drivers/misc/mediatek/video/mt6765/videox/kyocera/"
            "disp_ext_sub_panel_st7571.c")
    repl = [
        ("sdata pointer formats", "sdata[%x]", "sdata[%p]", 4),
        ("device-node pointer formats", "np[%x]", "np[%p]", 4),
        ("DT data pointer format", "dt_data_p[%x]", "dt_data_p[%p]", 1),
        ("pdata hex pointer formats", "pdata[%x]", "pdata[%p]", 6),
        ("pdata decimal pointer formats", "pdata[%d]", "pdata[%p]", 2),
        ("image pointer formats", "img[%x]", "img[%p]", 2),
        ("column pointer format",
         "img_p_colom[%x]", "img_p_colom[%p]", 1),
        ("command-data pointer format",
         "cmd data[%x]", "cmd data[%p]", 1),
        ("payload pointer formats", "payload[%x]", "payload[%p]", 3),
        ("fb_var pointer format", "var[%x]", "var[%p]", 1),
        ("fb_info pointer format", "info[%x]", "info[%p]", 1),
        ("sdata pointer casts", "(int)sdata", "sdata", 4),
        ("device-node pointer casts", "(int)np", "np", 4),
        ("DT data pointer cast", "(int)dt_data_p", "dt_data_p", 1),
        ("pdata pointer casts", "(int)pdata", "pdata", 8),
        ("image pointer cast", "(int)img_p", "img_p", 1),
        ("column pointer cast", "(int)img_p_colum", "img_p_colum", 1),
        ("command-data pointer cast", "(int)sub_cmds_p", "sub_cmds_p", 1),
        ("payload pointer casts", "(int)payload_p", "payload_p", 3),
        ("fb_var pointer cast", "(int)var", "var", 1),
        ("fb_info pointer cast", "(int)info", "info", 1),
        ("application image pointer cast",
         "(int)apps_img_p", "apps_img_p", 1),
    ]
    return apply_replacements(path, repl)


def fix_subdisplay_ld7032():
    path = ("drivers/misc/mediatek/video/mt6765/videox/kyocera/"
            "disp_ext_sub_panel_ld7032.c")
    repl = [
        ("pdata hex pointer formats", "pdata[%x]", "pdata[%p]", 8),
        ("pdata decimal pointer formats", "pdata[%d]", "pdata[%p]", 2),
        ("device-node pointer formats", "np[%x]", "np[%p]", 3),
        ("payload pointer formats", "payload[%x]", "payload[%p]", 3),
        ("image pointer formats", "img[%x]", "img[%p]", 3),
        ("fb_var pointer format", "var[%x]", "var[%p]", 1),
        ("fb_info pointer format", "info[%x]", "info[%p]", 1),
        ("command-data pointer format",
         "cmd data[%x]", "cmd data[%p]", 1),
        ("DT data pointer format", "dt_data_p[%x]", "dt_data_p[%p]", 1),
        ("pdata pointer casts", "(int)pdata", "pdata", 10),
        ("payload pointer casts", "(int)payload_p", "payload_p", 3),
        ("device-node pointer casts", "(int)np", "np", 3),
        ("image pointer casts", "(int)img_p", "img_p", 2),
        ("fb_var pointer cast", "(int)var", "var", 1),
        ("fb_info pointer cast", "(int)info", "info", 1),
        ("application image pointer cast",
         "(int)apps_img_p", "apps_img_p", 1),
        ("command-data pointer cast", "(int)sub_cmds_p", "sub_cmds_p", 1),
        ("DT data pointer cast", "(int)dt_data_p", "dt_data_p", 1),
    ]
    return apply_replacements(path, repl)


WAIVERS = {
    "drivers/misc/Makefile": r'''# ARM64 A0 compile-audit waiver.  The KY vibrator driver uses 32-bit integer
# casts only to print kernel pointer values.  Keep those sites visible as
# warnings while allowing the first AArch64 compile to continue far enough to
# inventory additional ISA-port blockers.  Replace the casts with %p before
# this waiver is removed for the stabilized port.
ifeq ($(CONFIG_ARM64),y)
CFLAGS_drv2604-vibrator.o += -Wno-error=pointer-to-int-cast
endif

''',
    "drivers/power/supply/mediatek/charger/Makefile": r'''# ARM64 A0 compile-audit waiver.  Five Kyocera factory sysfs store handlers
# log their size_t input with %d.  This is a diagnostic-format mismatch, not
# a data-path width conversion.  Keep it visible as a warning while the first
# AArch64 compile inventory proceeds; convert the formats to %zu afterwards.
ifeq ($(CONFIG_ARM64),y)
CFLAGS_mtk_charger.o += -Wno-error=format
endif

''',
    "drivers/misc/mediatek/leds/Makefile": r'''# ARM64 A0 compile-audit waivers.  These Kyocera LED drivers contain 32-bit
# pointer casts used only in error logging.  Preserve them as warnings during
# the first AArch64 blocker inventory; convert the logs to %p once the full
# compile surface is known.
ifeq ($(CONFIG_ARM64),y)
CFLAGS_leds-lp5569kc.o += -Wno-error=pointer-to-int-cast
CFLAGS_leds-lv5216kc.o += -Wno-error=pointer-to-int-cast
endif

''',
    ("drivers/misc/mediatek/video/mt6765/videox/kyocera/"
     "Makefile"): r'''# ARM64 A0 compile-audit waivers for the KY subdisplay cluster.  The current
# AArch32 code contains numerous pointer-to-32-bit casts and 32-bit printf
# formats used only for diagnostic output (including size_t and dma_addr_t
# values).  Keep those diagnostics visible as warnings while allowing the
# first AArch64 compile to continue and expose later blockers.  These are not
# stabilized-port fixes; convert the affected logs to %p/%zu/appropriate DMA
# formatting and remove these waivers once the full compile surface is known.
ifeq ($(CONFIG_ARM64),y)
ccflags-y += -Wno-error=pointer-to-int-cast -Wno-error=format
endif

''',
}


def remove_waivers():
    outputs = []
    for path, block in WAIVERS.items():
        text = read(path)
        count = text.count(block)
        if count == 1:
            new = text.replace(block, "")
            outputs.append((path, text, new, 1))
        elif count == 0:
            outputs.append((path, text, text, 0))
        else:
            raise CleanupError(
                "%s: expected 0 or 1 A0 waiver block, found %d" %
                (path, count))
    return outputs


def validate_clean(outputs):
    merged = {path: new for path, _old, new, _n in outputs}

    residuals = [
        ("arch/arm64/include/asm/assembler.h",
         r".if\t(\op == cvau || \op == cvac)",
         "symbol-valued dcache operation comparison"),
        ("drivers/misc/drv2604-vibrator.c",
         "0x%08x\\n\", (unsigned int)",
         "DRV2604 pointer logging via 32-bit integer"),
        ("drivers/power/supply/mediatek/charger/mtk_charger.c",
         "size is %d\\n",
         "charger size_t printed with %d"),
        ("drivers/misc/mediatek/leds/kyocera/leds-lp5569kc.c",
         "(unsigned int)&client->dev",
         "LP5569 device-pointer narrowing"),
        ("drivers/misc/mediatek/leds/kyocera/leds-lv5216kc.c",
         "(unsigned int)&client->dev",
         "LV5216 device-pointer narrowing"),
    ]

    for path, needle, label in residuals:
        text = merged.get(path, read(path))
        if needle in text:
            raise CleanupError("%s: residual %s" % (path, label))

    for path in WAIVERS:
        text = merged.get(path, read(path))
        if "-Wno-error=pointer-to-int-cast" in text:
            raise CleanupError("%s: residual pointer-cast A0 waiver" % path)
        if "CFLAGS_mtk_charger.o += -Wno-error=format" in text:
            raise CleanupError("%s: residual charger-format A0 waiver" % path)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true",
                      help="validate source shape and show pending changes")
    mode.add_argument("--apply", action="store_true",
                      help="write the provenance-guided cleanup")
    args = parser.parse_args()

    fixers = [
        fix_arm64_dcache,
        fix_drv2604,
        fix_charger,
        lambda: fix_led(
            "drivers/misc/mediatek/leds/kyocera/leds-lp5569kc.c",
            "LP5569"),
        lambda: fix_led(
            "drivers/misc/mediatek/leds/kyocera/leds-lv5216kc.c",
            "LV5216"),
        fix_subdisplay_ctrl,
        fix_subdisplay_dbg,
        fix_subdisplay_st7571,
        fix_subdisplay_ld7032,
    ]

    print("KY-42C ARM64 A0 provenance-guided cleanup")
    print("root=%s" % ROOT)

    try:
        outputs = [fixer() for fixer in fixers]
        outputs.extend(remove_waivers())
        validate_clean(outputs)
    except CleanupError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2

    changed = []
    for path, old, new, count in outputs:
        state = "change" if old != new else "clean"
        print("%-6s %3d  %s" % (state, count, path))
        if old != new:
            changed.append((path, old, new, count))

    if args.check:
        if changed:
            print("\nARM64_A0_CLEANUP_NEEDED")
            print("Run with --apply, inspect git diff, then rebuild.")
        else:
            print("\nARM64_A0_CLEANUP_ALREADY_APPLIED")
        return 0

    for path, _old, new, _count in changed:
        (ROOT / path).write_text(new)

    print("\nWrote %d file(s)." % len(changed))
    print("Review with:")
    print("  git diff --check")
    print("  git diff")
    print("\nARM64_A0_CLEANUP_APPLIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
