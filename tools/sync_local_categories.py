#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把内置目录里的旧分类名同步成后台整理后的分类名（纯字符串替换，不动其它逻辑）。

旧：风景 / 自然风光  ->  新：自然风景（后台已把两个分类合并）
同时把 CATEGORIES 列表改成与后台一致，供离线兜底的合辑分组使用。
"""
from pathlib import Path

P = Path(r"E:\zeroone\entry\src\main\ets\common\constants\LocalWallpapers.ets")
t = P.read_text(encoding="utf-8")
before = t

# 1) 构造函数里的分类字段：new Wallpaper('id', '标题', '风景', ...) / '自然风光'
t = t.replace("', '风景',", "', '自然风景',")
t = t.replace("', '自然风光',", "', '自然风景',")

# 2) CATEGORIES 常量列表
t = t.replace(
    "static readonly CATEGORIES: string[] = ['全部', '风景', '自然风光', '城市建筑', '极简风格', '动物萌宠'];",
    "static readonly CATEGORIES: string[] = ['全部', '自然风景', '动物萌宠', '城市建筑', '摄影作品', '极简风格'];")

if t != before:
    P.write_text(t, encoding="utf-8")
    print("updated:", P)
    print("  分类字段替换 / CATEGORIES 更新完成")
else:
    print("no change")

# 统计一下当前分布
import re
cats = re.findall(r"new Wallpaper\('[^']*', '[^']*', '([^']*)'", t)
from collections import Counter
print("  内置目录分类分布:", dict(Counter(cats)))
