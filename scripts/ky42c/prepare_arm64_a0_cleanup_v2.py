#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Boundary-safe runner for prepare_arm64_a0_cleanup.py.

The original A0 cleanup deliberately validates occurrence counts before it
writes anything. Some short format-string fragments can occur inside longer
identifiers in disabled/commented legacy code. This runner keeps strict count
validation, makes replacements identifier-boundary aware, and treats the
A0-observed counts in KY-specific dormant pointer diagnostics as lower bounds.
"""

from __future__ import print_function

import importlib.util
import re
import sys
from pathlib import Path

IMPL_PATH = Path(__file__).with_name("prepare_arm64_a0_cleanup.py")
SPEC = importlib.util.spec_from_file_location("ky42c_a0_cleanup_impl", str(IMPL_PATH))
IMPL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPL)

_IDENTIFIER = r"A-Za-z0-9_"
_SUBDISPLAY_PREFIX = (
    "drivers/misc/mediatek/video/mt6765/videox/kyocera/disp_ext_sub_"
)


def bounded_pattern(text):
    pattern = re.escape(text)
    if text and (text[0].isalnum() or text[0] == "_"):
        pattern = r"(?<![%s])" % _IDENTIFIER + pattern
    if text and (text[-1].isalnum() or text[-1] == "_"):
        pattern = pattern + r"(?![%s])" % _IDENTIFIER
    return pattern


def bounded_count(haystack, needle):
    return len(list(re.finditer(bounded_pattern(needle), haystack)))


def is_subdisplay_pointer_cleanup(path, label):
    if not path.startswith(_SUBDISPLAY_PREFIX):
        return False
    label_l = label.lower()
    return ("pointer format" in label_l or
            "pointer formats" in label_l or
            "pointer cast" in label_l or
            "pointer casts" in label_l)


def replace_expected(text, old, new, expected, path, label):
    """Strict replacement with identifier and subdisplay-source awareness."""
    old_pattern = bounded_pattern(old)
    old_count = len(list(re.finditer(old_pattern, text)))
    new_count = bounded_count(text, new)

    if old_count == expected:
        return re.sub(old_pattern, lambda _match: new, text), expected

    # A0 only reported compiled subdisplay branches. Clean the same exact
    # pointer-only idiom in dormant HW_SPI/feature branches as well.
    if (old_count > expected and
            is_subdisplay_pointer_cleanup(path, label)):
        print("expand %3d->%-3d  %s: %s" %
              (expected, old_count, path, label))
        return re.sub(old_pattern, lambda _match: new, text), old_count

    if old_count == 0 and new_count >= expected:
        return text, 0

    raise IMPL.CleanupError(
        "%s: %s: expected %d boundary-matched old occurrence(s), found %d "
        "(new form count=%d)" %
        (path, label, expected, old_count, new_count))


IMPL.replace_expected = replace_expected

# The DRV2604 source also contains a completely commented legacy
# remove/suspend/resume block. The A0 compiler never saw it, but the final
# source-wide residual check correctly notices its pointer-to-u32 diagnostics.
# Keep those comments width-clean too rather than weakening the validator.
_ORIG_FIX_DRV2604 = IMPL.fix_drv2604


def fix_drv2604_sourcewide():
    path, original, text, total = _ORIG_FIX_DRV2604()
    extras = [
        ("legacy pst_client pointer format",
         "called. pst_client=0x%08x\\n",
         "called. pst_client=%p\\n", 2),
        ("legacy pst_client/mesg pointer format",
         "called. pst_client=0x%08x,mesg=%d\\n",
         "called. pst_client=%p,mesg=%d\\n", 1),
        ("legacy pst_client pointer cast",
         "(unsigned int)pst_client", "pst_client", 3),
    ]
    for label, old, new, expected in extras:
        text, n = replace_expected(text, old, new, expected, path, label)
        total += n
    return path, original, text, total


IMPL.fix_drv2604 = fix_drv2604_sourcewide

if __name__ == "__main__":
    sys.exit(IMPL.main())
