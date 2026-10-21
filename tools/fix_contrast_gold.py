#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fifth pass: the two accent/gold text usages that were still just under threshold.

* the FAQ −/＋ indicator is 16vp (body size) -> needs 4.5:1, so it takes the lighter accent text tint
* gold #E6C07E on the dark shell is 4.97:1, i.e. under 4.5:1 — the whole gold-on-dark family
  moves one step lighter (#F0D08A: 6.77:1 on #264653, 6.9:1 on #0F0F12)
"""
from pathlib import Path

ROOT = Path(r"E:\zeroone\entry\src")

GOLD = "#E6C07E"
GOLD_LIGHT = "#F0D08A"

EDITS = {
    "main/ets/pages/MinePage.ets": [
        (329, "#C9333D", "#E8606A"),   # FAQ −/＋ at 16vp
    ],
    "main/ets/pages/HomePage.ets": [
        (411, GOLD, GOLD_LIGHT),       # offline notice text
    ],
    "main/ets/common/components/PrivacyConsentDialog.ets": [
        (42, GOLD, GOLD_LIGHT),
        (85, GOLD, GOLD_LIGHT),
    ],
    # 金色徽标底色保留原色（上面的深棕文字 6.97:1），只换"金色文字"
}

applied, skipped = 0, []
for rel, edits in EDITS.items():
    path = ROOT / rel
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    for lineno, old, new in edits:
        idx = lineno - 1
        if idx >= len(lines) or old not in lines[idx]:
            got = lines[idx].strip()[:70] if idx < len(lines) else "<EOF>"
            skipped.append((rel, lineno, old, got))
            continue
        lines[idx] = lines[idx].replace(old, new, 1)
        applied += 1
    path.write_text("".join(lines), encoding="utf-8")

print("applied %d / %d" % (applied, sum(len(v) for v in EDITS.values())))
for rel, lineno, old, got in skipped:
    print("  SKIPPED %s:%d expected %s | line: %s" % (rel, lineno, old, got))
