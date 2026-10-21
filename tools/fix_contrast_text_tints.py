#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Third pass: raise the remaining body-text contrast failures.

1. The accent red is fine as a *fill* (white on #C9333D = 5.22:1) but too dark as *text* on the
   dark shell (3.67:1 < 4.5:1), so accent-coloured text moves to a lighter tint.
2. The light editor panel's tertiary grey was 4.36:1 on #EEEEEE, a hair under 4.5:1.
3. The logout chip's text sat on its own 20 %-accent wash (3.29:1).
"""
from pathlib import Path
import re

ROOT = Path(r"E:\zeroone\entry\src")

# file -> list of (line, old, new)
EDITS = {
    "main/ets/common/components/CanvasView.ets": [
        (295, "#DD66666F", "#DD61616A"),
    ],
    "main/ets/common/components/ImageEditor.ets": [
        (1627, "#666666", "#61616A"),   # 滤镜强度百分比
        (1883, "#666666", "#61616A"),   # 贴纸尺寸百分比
    ],
    "main/ets/pages/MinePage.ets": [
        (472, "#C9333D", "#E8606A"),        # 退出（文字）
        (474, "#33C9333D", "#1FC9333D"),    # 退出胶囊底色
    ],
}

# accent-coloured *text* on the dark shell -> lighter tint (5.5:1 on #0F0F12 / 4.85:1 on #1C1D22)
TEXT_TINT = [
    ("main/ets/pages/HomePage.ets", [265, 423, 464]),
    ("main/ets/pages/MinePage.ets", [366, 422]),
    ("main/ets/pages/StickerPage.ets", [48]),
    ("main/ets/pages/StickerBoardPage.ets", [570, 571]),
    ("main/ets/pages/StickerStudioPage.ets", [703, 1224]),
    ("main/ets/common/components/LegalDocPage.ets", [242]),
]
for rel, linenos in TEXT_TINT:
    for n in linenos:
        EDITS.setdefault(rel, []).append((n, "#C9333D", "#E8606A"))

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

print("applied %d edits" % applied)
for rel, lineno, old, got in skipped:
    print("  SKIPPED %s:%d expected %s | line: %s" % (rel, lineno, old, got))
