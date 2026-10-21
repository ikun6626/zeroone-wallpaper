#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fourth pass: the last genuine contrast failures.

Entries whose foreground sits on an unpredictable *photo* background (the sticker canvas "－"
handle) are deliberately excluded — a fixed background colour cannot be verified there.
"""
from pathlib import Path

ROOT = Path(r"E:\zeroone\entry\src")

EDITS = {
    # 金色期号徽标上的错误码：白色在金色上只有 1.72:1，改用与徽标文字同色系的深棕
    "main/ets/pages/HomePage.ets": [
        (417, "#FFFFFF", "#4A3208"),
    ],
    # 注册页「同意协议」链接：青绿在浅青卡片上 3.32:1
    "main/ets/pages/RegisterPage.ets": [
        (227, "#2A9D8F", "#1B6B61"),
    ],
    # 裁剪面板标签：0xDD 透明度把 #61616A 冲淡到 4.01:1，提高不透明度
    "main/ets/common/components/CanvasView.ets": [
        (295, "#DD61616A", "#F261616A"),
    ],
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
