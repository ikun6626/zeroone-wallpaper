# -*- coding: utf-8 -*-
"""
把原始壁纸素材处理成云存储上传包

AGC 云存储需要两套尺寸：详情/下载用长边 1920，列表缩略图长边 720。本脚本一次产出：
  assets-out/detail/ID.jpg         详情图（长边 1920，q85）
  assets-out/thumb/ID_thumb.jpg    缩略图（长边 720，q80）
  assets-out/manifest.csv          版权台账 + 尺寸体积明细（审核补件用）
  assets-out/wallpapers-import.csv 可直接导入云数据库 wallpapers 表（URL 带占位前缀）

以后新增素材：把图片丢进源目录重跑本脚本；同 id 的已有产物会跳过，不会重复上传。

用法：E:\\Anaconda\\python.exe tools\\prepare_cloud_assets.py [源目录] [输出目录]
"""
import csv
import os
import re
import sys
import time

from PIL import Image, ImageOps

DEFAULT_SRC = r"Z:\背景图素材"
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets-out")

DETAIL_EDGE = 1920
THUMB_EDGE = 720
DETAIL_QUALITY = 85
THUMB_QUALITY = 80

# 上传到云存储后的公网地址前缀；上传完把这里改成真实域名再重跑，导入 CSV 即可直接用
URL_PREFIX = "https://REPLACE-WITH-BUCKET-DOMAIN"

# 云存储里的两个前缀（AGC 控制台里表现为两个文件夹）：
#   wallpapers/ 原图 —— 详情与下载用，将来可改私有 + 签名 URL 防盗链
#   thumbs/     缩略图 —— 列表要用，必须保持公共读
# 本地输出目录名与它们一致，上传时直接拖文件夹，不用手工对应。
DETAIL_PREFIX = "wallpapers"
THUMB_PREFIX = "thumbs"

CATEGORY_RULES = [
    ("动物萌宠", ["cat", "kitten", "dog", "puppy", "animal", "horse", "bird", "rabbit",
                  "wildlife", "fox", "lion", "tiger", "panda", "sheep", "cow", "pet",
                  "ridgeback", "corgi", "husky", "retriever"]),
    ("城市建筑", ["city", "street", "building", "architecture", "bridge", "tokyo", "japan",
                  "dubai", "skyline", "window", "urban", "metro", "station", "tower",
                  "downtown", "traffic", "harbor", "port"]),
    ("极简风格", ["minimal", "abstract", "geometry", "white", "simple", "pastel", "texture",
                  "wallpaper", "pattern", "gradient", "monochrome"]),
    ("自然风光", ["sunset", "sunrise", "lake", "mountain", "sky", "star", "milky", "aurora",
                  "forest", "beach", "sea", "ocean", "flower", "nature", "desert", "snow",
                  "autumn", "tree", "field", "cloud", "fog", "water", "river", "island",
                  "northern", "lights", "green", "leaf", "plant", "sun", "moon", "night",
                  "airplane", "plane", "jet", "landscape", "horizon", "valley", "waterfall",
                  "hotair", "balloon", "hill", "grass", "rock", "cliff", "ice", "winter"]),
]

SUBJECT_CN = {
    "cat": "猫咪", "dog": "狗狗", "puppy": "幼犬", "kitten": "幼猫",
    "sunset": "日落", "sunrise": "日出", "milky-way": "银河", "aurora": "极光",
    "northern-lights": "北极光", "lake": "湖畔", "mountain": "山峦", "beach": "海岸",
    "forest": "森林", "city": "城市", "street": "街景", "airplane": "航班",
    "japan": "日本", "flower": "花卉", "field": "原野", "sky": "天空",
}


def sanitize_id(name):
    """文件名 → 稳定 id：小写、非字母数字转下划线、去掉末尾尺寸后缀"""
    base = os.path.splitext(name)[0]
    base = re.sub(r"[^0-9a-zA-Z]+", "_", base).strip("_").lower()
    base = re.sub(r"_(1920|2560|3840|1080|720)$", "", base)
    return base or "img_" + str(int(time.time()))


def base_name(name):
    return os.path.splitext(name)[0].replace("-unsplash", "").lower()


def guess_author(name):
    """文件名猜作者：Pixabay 形如 author-subject-id，Unsplash 形如 author-slug-id-unsplash"""
    tokens = [t for t in base_name(name).split("-") if t]
    if not tokens:
        return ""
    known = set()
    for _, words in CATEGORY_RULES:
        known.update(words)
    parts = []
    for tok in tokens:
        if tok.isdigit() or tok in known:
            break
        parts.append(tok)
        if len(parts) >= 2:
            break
    return "-".join(parts)


def guess_subject(name):
    base = base_name(name)
    for _, words in CATEGORY_RULES:
        for w in words:
            if w in base:
                return w
    # 兜底：取最长的纯字母片段（Pixabay 文件名末尾常带内部数字 id，不能当主题用）
    tokens = [t for t in base.replace("_", "-").split("-")
              if len(t) >= 4 and t.isalpha()]
    if not tokens:
        return ""
    return max(tokens, key=len)


def guess_category(name):
    base = base_name(name)
    for category, words in CATEGORY_RULES:
        for w in words:
            if w in base:
                return category
    return "待归类"


def guess_title(name):
    subject = guess_subject(name)
    if subject in SUBJECT_CN:
        return SUBJECT_CN[subject]
    if subject:
        return subject.replace("-", " ").title()
    return "壁纸"


def resize_to_edge(img, edge):
    w, h = img.size
    long_edge = max(w, h)
    if long_edge <= edge:
        return img.copy()
    k = edge / float(long_edge)
    return img.resize((max(1, int(round(w * k))), max(1, int(round(h * k)))), Image.LANCZOS)


def kb(path):
    return round(os.path.getsize(path) / 1024.0, 1)


def parse_args(argv):
    """支持 --prefix 传入云存储域名，免得去改脚本源码"""
    prefix = URL_PREFIX
    positional = []
    i = 0
    while i < len(argv):
        if argv[i] in ("--prefix", "-p") and i + 1 < len(argv):
            prefix = argv[i + 1].strip().rstrip("/")
            i += 2
            continue
        positional.append(argv[i])
        i += 1
    return positional, prefix


def main():
    positional, prefix = parse_args(sys.argv[1:])
    src = positional[0] if len(positional) > 0 else DEFAULT_SRC
    out = positional[1] if len(positional) > 1 else DEFAULT_OUT
    # 本地目录名与云存储前缀保持一致，上传时整个文件夹拖进去即可
    detail_dir = os.path.join(out, DETAIL_PREFIX)
    thumb_dir = os.path.join(out, THUMB_PREFIX)
    os.makedirs(detail_dir, exist_ok=True)
    os.makedirs(thumb_dir, exist_ok=True)

    files = sorted(f for f in os.listdir(src) if f.lower().endswith((".jpg", ".jpeg", ".png")))
    if not files:
        print("源目录没有图片：" + src)
        return 1

    rows = []
    skipped = []
    failed = []
    for name in files:
        img_id = sanitize_id(name)
        detail_path = os.path.join(detail_dir, img_id + ".jpg")
        thumb_path = os.path.join(thumb_dir, img_id + "_thumb.jpg")
        reused = os.path.exists(detail_path) and os.path.exists(thumb_path)
        try:
            with Image.open(os.path.join(src, name)) as raw:
                img = ImageOps.exif_transpose(raw).convert("RGB")
                ow, oh = img.size
                if not os.path.exists(detail_path):
                    resize_to_edge(img, DETAIL_EDGE).save(
                        detail_path, "JPEG", quality=DETAIL_QUALITY, optimize=True, progressive=True)
                if not os.path.exists(thumb_path):
                    resize_to_edge(img, THUMB_EDGE).save(
                        thumb_path, "JPEG", quality=THUMB_QUALITY, optimize=True, progressive=True)
                with Image.open(detail_path) as d:
                    d_w, d_h = d.size
                with Image.open(thumb_path) as t:
                    t_w, t_h = t.size
        except Exception as exc:
            failed.append("%s: %s" % (name, exc))
            continue
        if reused:
            skipped.append(img_id)

        subject = guess_subject(name)
        category = guess_category(name)
        tags = ",".join([t for t in [category, SUBJECT_CN.get(subject, subject)] if t])
        rows.append({
            "id": img_id,
            "source_file": name,
            "author": guess_author(name),
            "subject": subject,
            "category": category,
            "title": guess_title(name),
            "orig_w": ow, "orig_h": oh,
            "detail_file": "%s/%s.jpg" % (DETAIL_PREFIX, img_id),
            "detail_w": d_w, "detail_h": d_h, "detail_kb": kb(detail_path),
            "thumb_file": "%s/%s_thumb.jpg" % (THUMB_PREFIX, img_id),
            "thumb_w": t_w, "thumb_h": t_h, "thumb_kb": kb(thumb_path),
            "upload_time": int(os.path.getmtime(os.path.join(src, name)) * 1000),
            "tags": tags,
            "license_note": "待逐张核对：Pixabay/Unsplash 均可商用，需保留来源页",
        })

    manifest = os.path.join(out, "manifest.csv")
    with open(manifest, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    import_csv = os.path.join(out, "wallpapers-import.csv")
    with open(import_csv, "w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.writer(fh)
        writer.writerow(["id", "title", "imageUrl", "thumbnailUrl", "category",
                         "author", "uploadTime", "tags", "ratingSum", "ratingCount"])
        for r in rows:
            writer.writerow([
                r["id"], r["title"],
                "%s/%s/%s.jpg" % (prefix, DETAIL_PREFIX, r["id"]),
                "%s/%s/%s_thumb.jpg" % (prefix, THUMB_PREFIX, r["id"]),
                r["category"], r["author"], r["upload_time"], r["tags"], 0, 0,
            ])

    total_detail = sum(r["detail_kb"] for r in rows) / 1024.0
    total_thumb = sum(r["thumb_kb"] for r in rows) / 1024.0
    print("源目录      : %s" % src)
    print("输出目录    : %s" % out)
    print("处理成功    : %d 张（其中 %d 张复用已有产物）" % (len(rows), len(skipped)))
    print("详情图合计  : %.1f MB（长边 %d）" % (total_detail, DETAIL_EDGE))
    print("缩略图合计  : %.1f MB（长边 %d）" % (total_thumb, THUMB_EDGE))
    print("版权台账    : %s" % manifest)
    print("导入用 CSV  : %s" % import_csv)
    if "REPLACE-WITH-BUCKET-DOMAIN" in prefix:
        print("")
        print("提醒：导入 CSV 里的域名还是占位符，App 读不到图。")
        print("      换成真实桶域名后重跑（图片会跳过重压，只重写 CSV）：")
        print("      E:\\Anaconda\\python.exe tools\\prepare_cloud_assets.py --prefix https://你的桶域名")
    if failed:
        print("失败 %d 张：" % len(failed))
        for line in failed:
            print("  - " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
