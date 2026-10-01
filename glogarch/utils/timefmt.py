# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Jason Cheng (Jason Tools)
"""Fast parsing of the fixed timestamp shapes archives actually contain.

Exporting and importing parse one timestamp per message; `datetime.strptime`
costs ~50-80 us each and tries format after format. Archived messages carry
one of two shapes — the REST API's `2026-09-27T08:00:00.000Z` and OpenSearch's
`2026-05-24 04:00:00.000` — so a regex plus integer slicing does the same work
in ~2 us.

The contract is exact equivalence with the strptime loop it sits in front of:
it accepts only the (separator, fraction, suffix) shapes the caller's own
formats accept, builds the same NAIVE datetime (a `Z` or `+00:00` suffix is
matched literally and dropped, exactly as `%Y-%m-%dT%H:%M:%S.%fZ` does), and
returns None for anything else so the caller falls back to strptime.
"""

from __future__ import annotations

import re
from datetime import datetime

_FIXED_TS = re.compile(
    r"(\d{4})-(\d{2})-(\d{2})([T ])(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|\+00:00)?\Z",
    re.ASCII,
)

# (separator, has fraction, suffix) for each strptime format.
SHAPE = {
    "%Y-%m-%dT%H:%M:%S.%fZ": ("T", True, "Z"),
    "%Y-%m-%dT%H:%M:%SZ": ("T", False, "Z"),
    "%Y-%m-%dT%H:%M:%S.%f+00:00": ("T", True, "+00:00"),
    "%Y-%m-%dT%H:%M:%S+00:00": ("T", False, "+00:00"),
    "%Y-%m-%d %H:%M:%S.%f": (" ", True, ""),
    "%Y-%m-%d %H:%M:%S": (" ", False, ""),
}


def shapes_for(formats) -> frozenset:
    """The shapes a strptime format list accepts (formats outside SHAPE add none)."""
    return frozenset(SHAPE[f] for f in formats if f in SHAPE)


def parse_fixed_naive(ts: str, shapes: frozenset) -> datetime | None:
    """Naive datetime for `ts` if it has one of `shapes`, else None."""
    m = _FIXED_TS.match(ts)
    if m is None:
        return None
    y, mo, d, sep, h, mi, s, frac, suffix = m.groups()
    if (sep, frac is not None, suffix or "") not in shapes:
        return None
    try:
        return datetime(int(y), int(mo), int(d), int(h), int(mi), int(s),
                        int(frac.ljust(6, "0")) if frac else 0)
    except ValueError:
        return None
