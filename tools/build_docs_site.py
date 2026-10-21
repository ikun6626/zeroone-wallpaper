# -*- coding: utf-8 -*-
"""
把工程里的 .md 文档生成一个可离线浏览的静态网页站点

- 纯静态：双击 index.html 就能看，不需要起服务器
- 深色主题，与 App 配色一致（近黑 #0F0F12 / 粉 #FF6B6B / 金 #E6C07E）
- 每页带左侧导航（当前页高亮）、代码高亮（pygments）、表格、TOC
- 自动把 .md 之间的相对链接改写成 .html

用法：E:\\Anaconda\\python.exe tools\\build_docs_site.py
"""
import io
import os
import re
import shutil

import markdown
from markdown.extensions.toc import TocExtension

ROOT = r"E:\zeroone"
OUT = os.path.join(ROOT, "docs-site")

# (源文件相对路径, 输出文件名, 标题, 副标题, 分组, 是否存档)
DOCS = [
    ("DELIVERY.md", "delivery.html", "交付说明", "当前状态、构建方式、已完成的取舍", "主文档", False),
    ("ARCHITECTURE.md", "architecture.html", "架构说明", "模块划分与数据流", "主文档", False),
    ("CHANGELOG.md", "changelog.html", "更新日志", "版本演进记录", "主文档", False),
    ("RESTRUCTURE-PLAN.md", "restructure-plan.html", "重构计划", "目录与模块的调整方案", "计划", False),
    ("AGC-云数据库接入步骤.md", "agc-cloud-steps.html", "AGC 云数据库接入步骤", "云端方案存档（已废弃）", "存档", True),
    ("CLOUD-ASSETS-AND-RELEASE-PLAN.md", "cloud-assets-plan.html",
     "云素材与发布计划", "云端方案存档（已废弃）", "存档", True),
    ("legal-site/README.md", "legal-site-readme.html", "法务文档站部署", "隐私政策站点的部署说明", "其他", False),
]

SITE_TITLE = "ZeroOne 壁纸 · 项目文档"

CSS = """
:root{--bg:#0f0f12;--card:#17171c;--card2:#1c1d22;--line:#2a2b33;--fg:#f2f2f5;
--dim:#b9b9c4;--mute:#7a7a85;--pink:#ff6b6b;--gold:#e6c07e;}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);
font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","HarmonyOS Sans SC","Microsoft YaHei",Segoe UI,Roboto,sans-serif;
font-size:15px;line-height:1.75}
a{color:var(--pink);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:flex;min-height:100vh;max-width:1280px;margin:0 auto}

/* 侧栏 */
aside{width:250px;flex:0 0 250px;border-right:1px solid var(--line);padding:22px 14px;
position:sticky;top:0;height:100vh;overflow-y:auto}
aside .brand{font-size:15px;font-weight:700;margin:0 0 4px 8px;letter-spacing:.3px}
aside .brand span{color:var(--gold)}
aside .ver{font-size:11.5px;color:var(--mute);margin:0 0 18px 8px}
aside .grp{font-size:11.5px;color:var(--mute);margin:16px 0 6px 8px;letter-spacing:.5px}
aside a.item{display:block;padding:7px 10px;border-radius:9px;color:var(--dim);font-size:13.5px;margin:2px 0}
aside a.item:hover{background:var(--card2);color:var(--fg);text-decoration:none}
aside a.item.on{background:#2a1f24;color:var(--gold);font-weight:600}
aside a.item .arc{font-size:10.5px;color:var(--mute);border:1px solid var(--line);
border-radius:6px;padding:0 5px;margin-left:6px}

/* 正文 */
main{flex:1;min-width:0;padding:34px 40px 80px}
main h1{font-size:26px;margin:0 0 6px;letter-spacing:.3px}
main .sub{color:var(--mute);font-size:13px;margin-bottom:8px}
main .src{color:var(--mute);font-size:12px;font-family:ui-monospace,Consolas,monospace;
background:var(--card2);border:1px solid var(--line);border-radius:7px;padding:1px 7px}
h2{font-size:19px;margin:36px 0 12px;padding-left:11px;border-left:3px solid var(--pink)}
h3{font-size:16px;margin:26px 0 8px;color:var(--gold)}
h4{font-size:14.5px;margin:20px 0 6px;color:var(--dim)}
p,li{color:var(--dim)}
strong{color:var(--fg)}
hr{border:0;border-top:1px solid var(--line);margin:32px 0}
img{max-width:100%;border-radius:10px}

ul,ol{padding-left:24px}
li{margin:4px 0}

code{background:var(--card2);border:1px solid var(--line);border-radius:5px;
padding:1px 5px;font-size:13px;color:var(--gold);
font-family:ui-monospace,SFMono-Regular,Consolas,monospace;word-break:break-word}
pre{background:#131318;border:1px solid var(--line);border-radius:11px;padding:14px 16px;
overflow-x:auto;margin:14px 0}
pre code{background:none;border:0;padding:0;color:#d8d8e0;font-size:13px;line-height:1.65}

table{width:100%;border-collapse:collapse;margin:14px 0;font-size:13.5px;display:block;overflow-x:auto}
th,td{text-align:left;padding:8px 11px;border-bottom:1px solid var(--line);
color:var(--dim);vertical-align:top;white-space:nowrap}
th{color:var(--fg);font-weight:600;background:var(--card2)}
tr:hover td{background:#16161b}

blockquote{margin:14px 0;padding:10px 16px;border-left:3px solid var(--gold);
background:var(--card);border-radius:0 10px 10px 0;color:var(--dim)}
blockquote p{margin:4px 0}

.archive{background:#2a1f1f;border:1px solid #6b4444;border-radius:11px;
padding:12px 16px;margin:0 0 22px;color:#ffb3b3;font-size:13.5px}
.archive b{color:#ffd0d0}

/* 目录页 */
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px;margin-top:22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;
display:block;transition:border-color .15s}
.card:hover{border-color:#4a4650;text-decoration:none}
.card h3{margin:0 0 5px;color:var(--fg);font-size:15.5px}
.card p{margin:0;color:var(--mute);font-size:13px}
.card .tag{display:inline-block;font-size:11px;color:var(--gold);border:1px solid var(--line);
border-radius:6px;padding:1px 7px;margin-top:9px}

.toc{background:var(--card);border:1px solid var(--line);border-radius:12px;
padding:12px 18px;margin:18px 0 26px;font-size:13px}
.toc .t{color:var(--mute);font-size:11.5px;letter-spacing:.5px;margin-bottom:6px}
.toc ul{margin:0;padding-left:18px}
.toc li{margin:2px 0}
.toc a{color:var(--dim)}

footer{margin-top:56px;padding-top:18px;border-top:1px solid var(--line);
color:var(--mute);font-size:12.5px}

@media(max-width:820px){
 .layout{display:block}
 aside{width:auto;flex:none;height:auto;position:static;border-right:0;
 border-bottom:1px solid var(--line);padding:16px 14px}
 main{padding:22px 18px 60px}
}
"""


def read(p):
    return io.open(p, encoding="utf-8").read()


def sidebar(cur_slug):
    parts = ['<p class="brand">ZeroOne <span>壁纸</span></p>',
             '<p class="ver">项目文档 · 生成于构建时</p>']
    groups = {}
    for src, slug, title, sub, grp, arc in DOCS:
        groups.setdefault(grp, []).append((slug, title, arc))
    for grp, items in groups.items():
        parts.append('<div class="grp">%s</div>' % grp)
        for slug, title, arc in items:
            cls = "item on" if slug == cur_slug else "item"
            badge = '<span class="arc">存档</span>' if arc else ""
            parts.append('<a class="%s" href="%s">%s%s</a>' % (cls, slug, title, badge))
    parts.append('<div class="grp">链接</div>')
    parts.append('<a class="item" href="index.html">📖 文档首页</a>')
    return "\n".join(parts)


def page(title, body, cur_slug, sub="", src=""):
    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · %s</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<div class="layout">
<aside>
%s
</aside>
<main>
%s
<footer>ZeroOne 壁纸 · 项目文档 · 本页由 <code>tools/build_docs_site.py</code> 从 Markdown 生成</footer>
</main>
</div>
</body>
</html>
""" % (title, SITE_TITLE, sidebar(cur_slug), body)


def fix_links(html):
    """把 .md 链接改写成 .html，并处理目录前缀"""
    mapping = {}
    for src, slug, *_ in DOCS:
        mapping[src.replace("\\", "/")] = slug
        mapping[os.path.basename(src)] = slug
    def repl(m):
        href = m.group(1)
        base = href.split("#")[0]
        frag = ("#" + href.split("#", 1)[1]) if "#" in href else ""
        key = base.replace("./", "")
        if key in mapping:
            return 'href="%s%s"' % (mapping[key], frag)
        return m.group(0)
    html = re.sub(r'href="([^"]+\.md(?:#[^"]*)?)"', repl, html)
    return html


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT, exist_ok=True)

    io.open(os.path.join(OUT, "style.css"), "w", encoding="utf-8", newline="\n").write(CSS)

    md = markdown.Markdown(extensions=[
        "extra",            # 含 tables / fenced_code / attr_list / def_list
        "sane_lists",
        "admonition",
        TocExtension(permalink=False, toc_depth="2-4"),
        "codehilite",
    ], extension_configs={"codehilite": {"guess_lang": False, "noclasses": False}})

    built = []
    for src, slug, title, sub, grp, arc in DOCS:
        path = os.path.join(ROOT, src.replace("/", os.sep))
        if not os.path.exists(path):
            print("  [跳过] 找不到 %s" % src)
            continue
        md.reset()
        body = md.convert(read(path))
        body = fix_links(body)
        toc = getattr(md, "toc", "")

        head = ['<h1>%s</h1>' % title]
        if sub:
            head.append('<p class="sub">%s</p>' % sub)
        head.append('<p class="src">%s</p>' % src.replace("\\", "/"))
        if arc:
            head.append('<div class="archive"><b>⚠️ 本文档已废弃</b> —— '
                        '云端数据库方案已整体移除，此处仅作历史存档，'
                        '不代表当前实现。最新状态请看「交付说明」。</div>')
        if toc:
            head.append('<div class="toc"><div class="t">本页目录</div>%s</div>' % toc)

        html = page(title, "\n".join(head) + "\n" + body, slug, sub, src)
        io.open(os.path.join(OUT, slug), "w", encoding="utf-8", newline="\n").write(html)
        built.append((slug, title, sub, grp, arc))
        print("  [OK] %-26s <- %s" % (slug, src))

    # 首页
    groups = {}
    for slug, title, sub, grp, arc in built:
        groups.setdefault(grp, []).append((slug, title, sub, arc))
    secs = []
    for grp, items in groups.items():
        cards = []
        for slug, title, sub, arc in items:
            tag = '<span class="tag">存档</span>' if arc else ""
            cards.append('<a class="card" href="%s"><h3>%s</h3><p>%s</p>%s</a>'
                         % (slug, title, sub, tag))
        secs.append('<h2>%s</h2><div class="cards">%s</div>' % (grp, "\n".join(cards)))

    home_body = ('<h1>项目文档</h1>'
                 '<p class="sub">ZeroOne 壁纸 · 全部 Markdown 文档的网页版</p>'
                 '<p class="src">共 %d 份文档</p>' % len(built) + "\n" + "\n".join(secs))
    io.open(os.path.join(OUT, "index.html"), "w", encoding="utf-8", newline="\n").write(
        page("文档首页", home_body, "index.html"))

    print("")
    print("生成完成：%s" % OUT)
    print("  打开方式：双击 %s" % os.path.join(OUT, "index.html"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
