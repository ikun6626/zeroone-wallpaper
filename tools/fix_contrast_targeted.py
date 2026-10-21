#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Second pass: targeted per-line contrast fixes that the global palette swap cannot express
(dark-theme greys landing on the light editor panel, light text on the accent chip, the
login page's translucent cards, the gold series badge).

Each entry is (relative path, 1-based line, expected old hex, new hex). The script refuses to
touch a line whose content does not contain the expected old hex, so a stale line number is
reported instead of silently corrupting code. Reads/writes UTF-8 without BOM.
"""
import sys
from pathlib import Path

ROOT = Path(r"E:\zeroone\entry\src")

# (file, line, old, new)
EDITS = [
    # ---------- 图片编辑器：浅色面板要有深色文字 ----------
    ("main/ets/common/components/ImageEditor.ets", 1414, "#A8A8B5", "#66666F"),  # 正在保存…
    ("main/ets/common/components/ImageEditor.ets", 1544, "#A8A8B5", "#66666F"),  # 折叠面板按钮
    ("main/ets/common/components/ImageEditor.ets", 1636, "#A8A8B5", "#66666F"),  # 微调
    ("main/ets/common/components/ImageEditor.ets", 1639, "#A8A8B5", "#66666F"),  # ▾/▸
    ("main/ets/common/components/ImageEditor.ets", 1665, "#A8A8B5", "#66666F"),  # 拉直
    ("main/ets/common/components/ImageEditor.ets", 1676, "#A8A8B5", "#66666F"),  # 角度值
    ("main/ets/common/components/ImageEditor.ets", 1684, "#A8A8B5", "#66666F"),  # 水平
    ("main/ets/common/components/ImageEditor.ets", 1695, "#A8A8B5", "#66666F"),  # 透视值
    ("main/ets/common/components/ImageEditor.ets", 1703, "#A8A8B5", "#66666F"),  # 垂直
    ("main/ets/common/components/ImageEditor.ets", 1714, "#A8A8B5", "#66666F"),  # 透视值
    ("main/ets/common/components/ImageEditor.ets", 1808, "#A8A8B5", "#66666F"),  # 强度
    ("main/ets/common/components/ImageEditor.ets", 1861, "#A8A8B5", "#66666F"),  # 贴纸尺寸
    ("main/ets/common/components/ImageEditor.ets", 2018, "#A8A8B5", "#66666F"),  # 我的贴纸标题
    ("main/ets/common/components/ImageEditor.ets", 2024, "#A8A8B5", "#66666F"),  # 相册导入按钮
    ("main/ets/common/components/ImageEditor.ets", 2063, "#A8A8B5", "#66666F"),  # 小贴士
    # ---------- 画布上的对照样张同样在浅色面板里 ----------
    ("main/ets/common/components/CanvasView.ets", 295, "#DDFFFFFF", "#DD66666F"),  # 无样式样张
    ("main/ets/common/components/CanvasView.ets", 418, "#A8A8B5", "#66666F"),      # 描边样张
    ("main/ets/common/components/CanvasView.ets", 505, "#333333", "#FFFFFF"),      # 选中手柄上的文字
    ("main/ets/common/components/CanvasView.ets", 668, "#A8A8B5", "#66666F"),      # 发光样张
    # ---------- 强调色胶囊/徽标上的次要文字改白 ----------
    ("main/ets/common/components/PrivacyConsentDialog.ets", 206, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/HomePage.ets", 390, "#A8A8B5", "#FFFFFF"),   # 分页失败重试
    ("main/ets/pages/HomePage.ets", 417, "#A8A8B5", "#FFFFFF"),   # 异常条重试
    ("main/ets/pages/MinePage.ets", 557, "#A8A8B5", "#FFFFFF"),   # 列表 > 箭头
    ("main/ets/pages/StickerBoardPage.ets", 475, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerBoardPage.ets", 487, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerStudioPage.ets", 930, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerStudioPage.ets", 942, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerStudioPage.ets", 954, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerStudioPage.ets", 966, "#A8A8B5", "#FFFFFF"),
    ("main/ets/pages/StickerStudioPage.ets", 1037, "#A8A8B5", "#FFFFFF"),
    # ---------- 金色期号徽标：正文用深棕，别用灰 ----------
    ("main/ets/pages/HomePage.ets", 398, "#1A1410", "#4A3208"),   # 「第 N 期」徽标文字
    ("main/ets/pages/MinePage.ets", 551, "#1A1410", "#FFFFFF"),   # 粉色计数徽标
    # ---------- 登录 / 注册：半透明卡片与渐变背景上的对比度 ----------
    ("main/ets/pages/LoginPage.ets", 83, "#E0FFFFFF", "#CC264653"),      # 跳过（磨砂胶囊）
    ("main/ets/pages/LoginPage.ets", 114, "#B0E0E0E0", "#CC264653"),     # 副标题
    ("main/ets/pages/LoginPage.ets", 134, "#A6264653", "#99264653"),     # 账号占位符
    ("main/ets/pages/LoginPage.ets", 158, "#A6264653", "#99264653"),     # 密码占位符
    ("main/ets/pages/LoginPage.ets", 183, "#E76F51", "#C24A32"),         # 错误提示
    ("main/ets/pages/LoginPage.ets", 212, "#E0FFFFFF", "#CC264653"),     # 底部提示
    ("main/ets/pages/RegisterPage.ets", 97, "#E0FFFFFF", "#CC264653"),
    ("main/ets/pages/RegisterPage.ets", 128, "#B0E0E0E0", "#CC264653"),
    ("main/ets/pages/RegisterPage.ets", 148, "#A6264653", "#99264653"),
    ("main/ets/pages/RegisterPage.ets", 172, "#A6264653", "#99264653"),
    ("main/ets/pages/RegisterPage.ets", 206, "#A6264653", "#99264653"),
    ("main/ets/pages/RegisterPage.ets", 220, "#E76F51", "#C24A32"),
]

applied, skipped = 0, []
for rel, lineno, old, new in EDITS:
    path = ROOT / rel
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    if lineno - 1 >= len(lines) or old not in lines[lineno - 1]:
        skipped.append((rel, lineno, old, lines[lineno - 1].strip()[:70] if lineno - 1 < len(lines) else "<EOF>"))
        continue
    lines[lineno - 1] = lines[lineno - 1].replace(old, new, 1)
    path.write_text("".join(lines), encoding="utf-8")
    applied += 1

print("applied %d / %d" % (applied, len(EDITS)))
for rel, lineno, old, got in skipped:
    print("  SKIPPED %s:%d expected %s but line is: %s" % (rel, lineno, old, got))
