#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Boundary-safe runner for prepare_arm64_a0_cleanup.py.

The original A0 cleanup deliberately validates occurrence counts before it
writes anything.  Some of its short format-string fragments can also occur as
substrings of longer identifiers in disabled/commented legacy code (for
example `client=...` inside `pst_client=...`).  This runner keeps the strict
count validation but makes replacements identifier-boundary aware, then calls
the original implementation unchanged.

This is intentionally a small compatibility layer so the provenance cleanup
can be validated on the real KY-42C source before the matcher is folded back
into the main tool.
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


def bounded_pattern(text):
    pattern = re.escape(text)
    if text and (text[0].isalnum() or text[0] == "_"):
        pattern = r"(?<![%s])" % _IDENTIFIER + pattern
    if text and (text[-1].isalnum() or text[-1] == "_"):
        pattern = pattern + r"(?![%s])" % _IDENTIFIER
    return pattern


def bounded_count(haystack, needle):
    return len(list(re.finditer(bounded_pattern(needle), haystack)))


def replace_expected(text, old, new, expected, path, label):
    """Strict replacement, but do not match inside a longer identifier."""
    old_pattern = bounded_pattern(old)
    old_count = len(list(re.finditer(old_pattern, text)))
    new_count = bounded_count(text, new)

    if old_count == expected:
        return re.sub(old_pattern, lambda _match: new, text), expected

    # Preserve the original tool's idempotent second-run behavior.
    if old_count == 0 and new_count >= expected:
        return text, 0

    raise IMPL.CleanupError(
        "%s: %s: expected %d boundary-matched old occurrence(s), found %d "
        "(new form count=%d)" %
        (path, label, expected, old_count, new_count))


IMPL.replace_expected = replace_expected

if __name__ == "__main__":
    sys.exit(IMPL.main())
