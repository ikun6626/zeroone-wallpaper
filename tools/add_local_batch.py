# -*- coding: utf-8 -*-
"""
把一批外部素材压缩后加入工程（离线版）

做的事情：
  1. 扫描源目录里的图片（jpg/png 都收，png 会转成 jpg —— 这批 png 平均 2.7 MB，转完能省 90%）
  2. 主图压到长边 EDGE / q，缩略图压到长边 THUMB_EDGE / q，直接写进 resources/base/media/
     命名：wp_<id>.jpg 与 wp_<id>_thumb.jpg（资源名必须以字母开头，所以统一加 wp_ 前缀）
  3. 把条目写进 assets-local/batches/<批名>.csv，供 gen_local_catalog.py 合并

id 取文件名里去掉中文前缀后的部分，例如：
  风景_100_2468fdfb76.jpg  ->  id = 100_2468fdfb76  ->  资源名 wp_100_2468fdfb76

用法：
  E:\\Anaconda\\python.exe tools\\add_local_batch.py <源目录> <批名> <分类>
  例：... tools\\add_local_batch.py "Z:\\素材\\bz_images\\风景" scenery 自然风光
"""
import csv
import os
import re
import sys

from PIL import Image, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "entry", "src", "main", "resources", "base", "media")
BATCH_DIR = os.path.join(ROOT, "assets-local", "batches")

# 极限压缩档（见试算：232 张约 15.7 MB）
EDGE = 1080
QUALITY = 68
THUMB_EDGE = 400
THUMB_QUALITY = 68

# 资源名只允许小写字母/数字/下划线，且必须以字母开头
NAME_OK = re.compile(r"^[a-z][a-z0-9_]*$")


def make_id(stem):
    """去掉中文前缀，只留 ASCII 部分作为 id"""
    ascii_part = re.sub(r"[^0-9a-zA-Z_]+", "_", stem)
    ascii_part = re.sub(r"_+", "_", ascii_part).strip("_").lower()
    if not ascii_part:
        return None
    if not ascii_part[0].isalpha():
        ascii_part = "w" + ascii_part          # 不能以数字开头
    return ascii_part


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    src_dir, batch, category = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isdir(src_dir):
        print("源目录不存在: %s" % src_dir)
        return 1
    os.makedirs(MEDIA, exist_ok=True)
    os.makedirs(BATCH_DIR, exist_ok=True)

    files = sorted(f for f in os.listdir(src_dir)
                   if os.path.splitext(f)[1].lower() in (".jpg", ".jpeg", ".png", ".webp"))
    print("源目录: %s" % src_dir)
    print("文件数: %d   批名: %s   分类: %s" % (len(files), batch, category))
    print("档位: 主图长边 %d q%d ／ 缩略图长边 %d q%d" % (EDGE, QUALITY, THUMB_EDGE, THUMB_QUALITY))
    print("")

    rows = []
    seen = set()
    main_total = 0
    thumb_total = 0
    skipped = 0

    for f in files:
        stem = os.path.splitext(f)[0]
        wid = make_id(stem)
        if wid is None:
            print("  [跳过] 无法生成合法 id: %s" % f)
            skipped += 1
            continue
        if wid in seen:
            print("  [跳过] id 重复: %s" % wid)
            skipped += 1
            continue

        res = "wp_" + wid
        if not NAME_OK.match(res):
            print("  [跳过] 资源名不合法: %s" % res)
            skipped += 1
            continue

        src = os.path.join(src_dir, f)
        dst_main = os.path.join(MEDIA, res + ".jpg")
        dst_thumb = os.path.join(MEDIA, res + "_thumb.jpg")

        try:
            with Image.open(src) as im:
                im = ImageOps.exif_transpose(im).convert("RGB")

                m = im.copy()
                s = float(EDGE) / float(max(m.size))
                if s < 1.0:
                    m = m.resize((max(1, int(m.size[0] * s)), max(1, int(m.size[1] * s))), Image.LANCZOS)
                m.save(dst_main, "JPEG", quality=QUALITY, optimize=True, progressive=True)

                ts = float(THUMB_EDGE) / float(max(m.size))
                t = m.resize((max(1, int(m.size[0] * ts)), max(1, int(m.size[1] * ts))), Image.LANCZOS)
                t.save(dst_thumb, "JPEG", quality=THUMB_QUALITY, optimize=True, progressive=True)
        except Exception as e:
            print("  [失败] %s : %s" % (f, e))
            skipped += 1
            continue

        seen.add(wid)
        main_total += os.path.getsize(dst_main)
        thumb_total += os.path.getsize(dst_thumb)

        mtime = int(os.path.getmtime(src) * 1000)
        num = stem.split("_")[1] if "_" in stem else stem
        rows.append({
            "id": wid,
            "title": "%s %s" % (category, num),
            "category": category,
            "author": "",
            "uploadTime": str(mtime),
            "tags": "%s,%s" % (category, batch),
        })

    csv_path = os.path.join(BATCH_DIR, batch + ".csv")
    with open(csv_path, "w", encoding="utf-8", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=["id", "title", "category", "author", "uploadTime", "tags"])
        w.writeheader()
        w.writerows(rows)

    print("")
    print("写入清单: %s（%d 条）" % (csv_path, len(rows)))
    print("主图合计: %.1f MB（平均 %.0f KB）" % (main_total / 1048576.0, main_total / max(1, len(rows)) / 1024.0))
    print("缩略图合计: %.1f MB（平均 %.0f KB）" % (thumb_total / 1048576.0, thumb_total / max(1, len(rows)) / 1024.0))
    print("新增合计: %.1f MB" % ((main_total + thumb_total) / 1048576.0))
    print("跳过: %d" % skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
