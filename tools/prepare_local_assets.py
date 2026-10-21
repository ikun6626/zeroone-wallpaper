# -*- coding: utf-8 -*-
"""
把壁纸素材处理成"随包内置"的本地资源（离线版）

与 prepare_cloud_assets.py 的区别：
  - 只产出一套图，长边 1440 / q80，用于直接打进 HAP（不再需要两套尺寸）
  - 输出到 assets-local/wallpapers/ID.jpg，文件名 = 云数据库里的 id，方便和旧数据对齐
  - 优先从原始素材 Z:\\背景图素材 重压（画质最好）；原始素材不在时回退到 assets-out/wallpapers

用法：
  E:\\Anaconda\\python.exe tools\\prepare_local_assets.py
"""
import csv
import os
import sys

from PIL import Image, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "assets-out", "manifest.csv")
SRC_DIR = r"Z:\背景图素材"
FALLBACK_DIR = os.path.join(ROOT, "assets-out", "wallpapers")
OUT_DIR = os.path.join(ROOT, "assets-local", "wallpapers")

EDGE = 1440
QUALITY = 80


def load_rows():
    with open(MANIFEST, "r", encoding="utf-8-sig", newline="") as f:
        return [r for r in csv.DictReader(f) if r.get("id")]


def pick_source(row):
    """优先原始素材，其次 assets-out 里 1920 的那份。"""
    src_name = (row.get("source_file") or "").strip()
    if src_name:
        p = os.path.join(SRC_DIR, src_name)
        if os.path.exists(p):
            return p, "原素材"
    p = os.path.join(FALLBACK_DIR, row["id"] + ".jpg")
    if os.path.exists(p):
        return p, "assets-out(1920)"
    return None, None


def main():
    if not os.path.exists(MANIFEST):
        print("找不到 manifest.csv: %s" % MANIFEST)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)

    rows = load_rows()
    print("清单条数: %d" % len(rows))
    print("输出目录: %s" % OUT_DIR)
    print("")

    total = 0
    max_kb = 0
    max_id = ""
    src_stat = {}

    for row in rows:
        wid = row["id"]
        src_path, src_kind = pick_source(row)
        if src_path is None:
            print("  [跳过] 找不到源文件: %s" % wid)
            continue
        src_stat[src_kind] = src_stat.get(src_kind, 0) + 1

        dst = os.path.join(OUT_DIR, wid + ".jpg")
        try:
            with Image.open(src_path) as im:
                im = ImageOps.exif_transpose(im)          # 按 EXIF 摆正
                im = im.convert("RGB")
                w, h = im.size
                scale = float(EDGE) / float(max(w, h))
                if scale < 1.0:
                    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
                    im = im.resize((nw, nh), Image.LANCZOS)
                else:
                    nw, nh = w, h
                im.save(dst, "JPEG", quality=QUALITY, optimize=True, progressive=True)
        except Exception as e:
            print("  [失败] %s : %s" % (wid, e))
            continue

        kb = os.path.getsize(dst) / 1024.0
        total += kb
        if kb > max_kb:
            max_kb, max_id = kb, wid

    print("")
    print("来源统计: %s" % ", ".join("%s=%d" % (k, v) for k, v in src_stat.items()))
    print("产出文件: %d 个" % len(os.listdir(OUT_DIR)))
    print("合计体积: %.2f MB" % (total / 1024.0))
    print("平均: %.0f KB   最大: %.0f KB (%s)" % (total / max(1, len(rows)), max_kb, max_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
