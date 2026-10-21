#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Refresh the theme comments so they match the shipped palette (comments only)."""
from pathlib import Path

ROOT = Path(r"E:\zeroone\entry\src\main\ets")

EDITS = [
    ("pages/Index.ets",
     "主题：近黑背景 #0F0F12 · 强调粉 #FF6B6B · 精选金 #E6C07E",
     "主题：近黑背景 #0F0F12 · 强调红 #C9333D（底色）/ #E8606A（深色底上的文字）· 精选金 #F0D08A\n *\n * 配色以应用市场「色彩对比度」审核项为准：正文文字与背景 ≥ 4.5:1，图标/标题 ≥ 3:1。\n * 改动配色时请跑 tools/contrast_audit.py 复核（详见《整改说明-1.1.0-色彩与动效.md》）。"),
    ("pages/HomePage.ets",
     "顶部「今日精选 · 第 N 期」徽标（金 #E6C07E）",
     "顶部「今日精选 · 第 N 期」徽标（金底 #E6C07E + 深棕字 #4A3208，6.97:1）"),
]

for rel, old, new in EDITS:
    p = ROOT / rel
    t = p.read_text(encoding="utf-8")
    if old in t:
        p.write_text(t.replace(old, new, 1), encoding="utf-8")
        print("updated comment:", rel)
    else:
        print("comment not found (already updated?):", rel)
