#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""WCAG contrast audit for the ArkTS sources.

Pairs every fontColor/placeholderColor/iconColor/selectedColor/blockColor/fill with the
nearest known backgroundColor, tracking nesting depth through *string-literal-aware* brace
counting (the earlier PowerShell version counted braces inside strings and reported noise).

Thresholds follow 华为应用市场审核指南:
  * 正文文字 vs 背景 >= 4.5:1   (font size < 18vp, or < 14vp bold)
  * 图标/标题文字 vs 背景 >= 3:1
"""
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else r"E:\zeroone\entry\src\main\ets")

FG_RE = re.compile(
    r"\.(fontColor|placeholderColor|iconColor|selectedColor|blockColor|fill)\("
    r"\s*'(#[0-9A-Fa-f]{3,8})'"
)
BG_RE = re.compile(r"\.backgroundColor\(\s*'(#[0-9A-Fa-f]{3,8})'")
SIZE_RE = re.compile(r"\.fontSize\((\d+(?:\.\d+)?)\)")
BOLD_RE = re.compile(r"FontWeight\.(Bold|Bolder|Medium)")
GRAPHIC = {"iconColor", "selectedColor", "blockColor", "fill"}
PAGE_BG = "#0F0F12"          # dark shell
LIGHT_PANEL_BG = "#EEEEEE"   # editor / light panels

# Fallback background per file region when nothing is declared nearby.
FALLBACKS = [
    ("common\\components\\ImageEditor.ets", LIGHT_PANEL_BG),
    ("common\\components\\CanvasView.ets", LIGHT_PANEL_BG),
    ("pages\\LoginPage.ets", "#F5FAFA"),
    ("pages\\RegisterPage.ets", "#F5FAFA"),
]


def parse(hexstr):
    h = hexstr.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if len(h) == 8:
        a, r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4, 6))
        return a / 255.0, r, g, b
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 1.0, r, g, b


def over(fg, bg):
    """Composite fg (with alpha) over bg."""
    a, r, g, b = fg
    _, br, bg_, bb = bg
    return 1.0, r * a + br * (1 - a), g * a + bg_ * (1 - a), b * a + bb * (1 - a)


def lum(c):
    def f(v):
        s = v / 255.0
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(c[1]) + 0.7152 * f(c[2]) + 0.0722 * f(c[3])


def ratio(fg_hex, bg_hex):
    fg, bg = parse(fg_hex), parse(bg_hex)
    if fg[0] < 1.0:
        fg = over(fg, bg)
    l1, l2 = lum(fg), lum(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def strip_strings(line):
    """Remove the *contents* of string literals so braces inside them don't count."""
    return re.sub(r"'[^']*'|\"[^\"]*\"|`[^`]*`", "''", line)


def fallback_for(relpath):
    for frag, bg in FALLBACKS:
        if relpath.replace("/", "\\").endswith(frag):
            return bg
    return PAGE_BG


def audit(path):
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    rel = str(path.relative_to(ROOT))
    default_bg = fallback_for(rel)
    stack = [default_bg]
    pending = {}       # depth -> backgroundColor declared in this block
    last_bg = default_bg
    depth_bg = [default_bg]   # resolved background of the block currently open at each depth
    bg_depth = -1             # depth at which the last backgroundColor was declared
    out = []

    for i, line in enumerate(lines):
        depth = len(stack) - 1
        m = BG_RE.search(line)
        if m:
            pending[depth] = m.group(1)
            bg_depth = depth
            depth_bg[depth] = m.group(1)

        for fm in FG_RE.finditer(line):
            prop, fg = fm.group(1), fm.group(2)
            # Only trust a background declared in the *same* block as the foreground; a
            # sibling's background (e.g. a Slider's own .blockColor) must not be borrowed.
            bg = pending.get(depth, default_bg) if bg_depth == depth else default_bg
            if bg.upper() == fg.upper():
                continue
            size, bold = 14.0, False
            for k in range(max(0, i - 12), min(len(lines), i + 3)):
                s = SIZE_RE.search(lines[k])
                if s:
                    size = float(s.group(1))
                if BOLD_RE.search(lines[k]):
                    bold = True
            graphic = prop in GRAPHIC
            large = size >= 18 or (bold and size >= 14)
            need = 3.0 if (graphic or large) else 4.5
            r = ratio(fg, bg)
            if r < need - 1e-9:
                out.append({
                    "file": rel, "line": i + 1, "prop": prop, "fg": fg, "bg": bg,
                    "size": size, "need": need, "ratio": round(r, 2),
                    "text": line.strip()[:78],
                })

        s = strip_strings(line)
        opens = s.count("{")
        closes = s.count("}")
        for _ in range(opens):
            stack.append(last_bg)
            depth_bg.append(default_bg)
        for _ in range(closes):
            d = len(stack) - 1
            pending.pop(d, None)
            if bg_depth == d:
                bg_depth = -1      # the declared background dies with its block
            if len(stack) > 1:
                stack.pop()
                depth_bg.pop()
        last_bg = depth_bg[-1]
    return out


rows = []
for p in sorted(ROOT.rglob("*.ets")):
    rows.extend(audit(p))

rows.sort(key=lambda r: r["ratio"])
print("%-44s %5s %-16s %-9s %-9s %5s %5s" % ("FILE", "LINE", "PROP", "FG", "BG", "RATIO", "NEED"))
for r in rows:
    print("%-44s %5d %-16s %-9s %-9s %5.2f %5.1f  %s"
          % (r["file"], r["line"], r["prop"], r["fg"], r["bg"], r["ratio"], r["need"], r["text"]))
print("\nTOTAL below threshold: %d" % len(rows))
