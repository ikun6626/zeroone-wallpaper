#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render 审核整改说明 to a print-ready HTML (for PDF export).
源文档已从仓库移出，归档在本机 .local/private/docs-archive/，使用前先放回该路径。

Deliberately dependency-light: python-markdown + a small CJK-friendly stylesheet.
"""
import re
from pathlib import Path

import markdown

SRC = Path(r"E:\zeroone\整改说明-1.1.0-色彩与动效.md")
OUT_HTML = Path(r"E:\zeroone\整改说明-1.1.0-色彩与动效.html")

CSS = """
:root { color-scheme: light; }
* { box-sizing: border-box; }
body {
  font-family: "Microsoft YaHei", "微软雅黑", "PingFang SC", "Noto Sans CJK SC", sans-serif;
  font-size: 13px; line-height: 1.75; color: #1c1d22; max-width: 900px;
  margin: 0 auto; padding: 32px 40px 56px;
}
h1 { font-size: 24px; border-bottom: 3px solid #c9333d; padding-bottom: 10px; margin: 8px 0 20px; }
h2 { font-size: 18px; margin: 30px 0 12px; padding-left: 10px; border-left: 4px solid #c9333d; }
h3 { font-size: 15px; margin: 22px 0 8px; color: #7a2b31; }
p, li { margin: 6px 0; }
strong { color: #7a2b31; }
code {
  font-family: Consolas, "Courier New", monospace; font-size: 12px;
  background: #f4f4f6; border: 1px solid #e3e3e8; border-radius: 4px; padding: 1px 5px;
}
pre { background: #1c1d22; color: #f2f2f5; padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; border: none; color: inherit; padding: 0; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 12.5px; }
th, td { border: 1px solid #d8d8de; padding: 6px 9px; text-align: left; vertical-align: top; }
th { background: #f4f4f6; font-weight: 600; }
tr:nth-child(even) td { background: #fafafc; }
blockquote {
  margin: 12px 0; padding: 8px 14px; background: #fff6f7;
  border-left: 4px solid #c9333d; color: #4a2e36;
}
hr { border: none; border-top: 1px dashed #cfcfd6; margin: 26px 0; }
a { color: #b3252f; }
@media print {
  body { padding: 0; font-size: 12px; }
  h2 { page-break-after: avoid; }
  table, pre, blockquote { page-break-inside: avoid; }
}
"""

text = SRC.read_text(encoding="utf-8")
body = markdown.markdown(text, extensions=["tables", "fenced_code", "sane_lists", "attr_list"])
# 让标题层级从正文开始，避免 h1 重复渲染两遍
html = (
    "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n"
    "<title>ZeroOne 壁纸 1.1.0 审核整改说明</title>\n<style>%s</style>\n</head>\n<body>\n%s\n</body>\n</html>\n"
    % (CSS, body)
)
OUT_HTML.write_text(html, encoding="utf-8")
print("html written:", OUT_HTML, len(html), "chars")
