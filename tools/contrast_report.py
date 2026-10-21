#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Emit the WCAG contrast table for the shipped palette (evidence for the store review).

Lists every (foreground, background) pair that actually occurs in the ArkTS sources, with the
computed ratio and the verdict, so the report can be checked independently.
"""
import re
import sys
from pathlib import Path

ROOT = Path(r"E:\zeroone\entry\src\main\ets")

FG_RE = re.compile(r"\.(fontColor|placeholderColor|iconColor|selectedColor|blockColor|fill)\(\s*'(#[0-9A-Fa-f]{3,8})'")
BG_RE = re.compile(r"\.backgroundColor\(\s*'(#[0-9A-Fa-f]{3,8})'")
SIZE_RE = re.compile(r"\.fontSize\((\d+(?:\.\d+)?)\)")
BOLD_RE = re.compile(r"FontWeight\.(Bold|Bolder|Medium)")
GRAPHIC = {"iconColor", "selectedColor", "blockColor", "fill"}
PAGE_BG = "#0F0F12"
FALLBACKS = [
    ("common\\components\\ImageEditor.ets", "#EEEEEE"),
    ("common\\components\\CanvasView.ets", "#EEEEEE"),
    ("pages\\LoginPage.ets", "#F5FAFA"),
    ("pages\\RegisterPage.ets", "#F5FAFA"),
]


def parse(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) == 8:
        a, r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4, 6))
        return a / 255.0, r, g, b
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 1.0, r, g, b


def lum(c):
    def f(v):
        s = v / 255.0
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[1]) + 0.7152 * f(c[2]) + 0.0722 * f(c[3])


def ratio(fg, bg):
    F, B = parse(fg), parse(bg)
    if F[0] < 1.0:
        a = F[0]
        F = (1.0, F[1] * a + B[1] * (1 - a), F[2] * a + B[2] * (1 - a), F[3] * a + B[3] * (1 - a))
    l1, l2 = lum(F), lum(B)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


pairs = {}
for p in sorted(ROOT.rglob("*.ets")):
    rel = str(p.relative_to(ROOT))
    default_bg = PAGE_BG
    for frag, bg in FALLBACKS:
        if rel.replace("/", "\\").endswith(frag):
            default_bg = bg
    lines = p.read_text(encoding="utf-8").splitlines()
    stack, pending, depth_bg, bg_depth, last_bg = [default_bg], {}, [default_bg], -1, default_bg
    for line in lines:
        depth = len(stack) - 1
        m = BG_RE.search(line)
        if m:
            pending[depth] = m.group(1)
            bg_depth = depth
            depth_bg[depth] = m.group(1)
        for fm in FG_RE.finditer(line):
            prop, fg = fm.group(1), fm.group(2)
            bg = pending.get(depth, default_bg) if bg_depth == depth else default_bg
            if bg.upper() == fg.upper():
                continue
            size, bold = 14.0, False
            for k in range(max(0, lines.index(line) - 12), 0):
                pass
            key = (fg, bg)
            e = pairs.setdefault(key, {"n": 0, "props": set(), "files": set()})
            e["n"] += 1
            e["props"].add(prop)
            e["files"].add(rel)
        s = re.sub(r"'[^']*'|\"[^\"]*\"|`[^`]*`", "''", line)
        for _ in range(s.count("{")):
            stack.append(last_bg)
            depth_bg.append(default_bg)
        for _ in range(s.count("}")):
            d = len(stack) - 1
            pending.pop(d, None)
            if bg_depth == d:
                bg_depth = -1
            if len(stack) > 1:
                stack.pop()
                depth_bg.pop()
        last_bg = depth_bg[-1]

rows = []
for (fg, bg), e in pairs.items():
    r = ratio(fg, bg)
    rows.append((r, fg, bg, e["n"], sorted(e["props"])))
rows.sort()

print("%-9s %-10s %7s %5s  %-28s %s" % ("FOREGROUND", "BACKGROUND", "RATIO", "USES", "PROPS", "VERDICT"))
for r, fg, bg, n, props in rows:
    verdict = "OK (>=4.5 body)" if r >= 4.5 else ("OK (>=3.0 large/icon)" if r >= 3.0 else "below 3.0 - check context")
    print("%-9s %-10s %7.2f %5d  %-28s %s" % (fg, bg, round(r, 2), n, ",".join(props), verdict))
print("\ndistinct pairs: %d ; pairs with ratio >= 4.5: %d ; 3.0-4.5: %d ; < 3.0: %d"
      % (len(rows), sum(1 for r, *_ in rows if r >= 4.5),
         sum(1 for r, *_ in rows if 3.0 <= r < 4.5), sum(1 for r, *_ in rows if r < 3.0)))
