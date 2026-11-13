# -*- coding: utf-8 -*-
"""
11.3 新素材导入（WorkBuddy 标签成品 + 本地画质门槛 + pHash 去重）

流程（全部可复现，不会静默降门槛）：
  1. 读 docs/workbuddy-image-tags-final.csv（只读，不修改），按 relative_path 精确匹配源文件；
  2. 实际存在、可解码、短边 ≥1080、比例 9:16~9:21 的才进入候选；
  3. 算 64bit pHash / SHA-256 / 宽高 / 体积 / mtime；
  4. 候选内部 pHash ≤6 去重（保留：分辨率最高 → 体积最大 → mtime 最早 → 文件名/id 字典序）；
  5. 与当前 App 目录的其他既有主图比对，≤6 视为重复，不得导入；
  6. 幂等：当前批次自己的 CSV 不参与“既有主图”比对；app_id 已在批次 CSV 且主图/缩略图都在的，
     识别为 ALREADY_IMPORTED，第二次执行成功但零写入；
  7. 只有候选数正好等于 --expect（默认 27）才写资源；否则停止并如实报告，不硬凑；
  8. 主图/缩略图按现有工程压缩参数（长边 1080 q68 / 长边 400 q68）写入 resources/base/media；
  9. 写 assets-local/batches/<批次>.csv 与 docs/11.3-导入清单-2026-11-07.csv（临时文件 + 原子替换）。

模式：
  默认          真实导入 / 幂等复跑
  --dry-run     零写入：只打印统计与差异，不写 media、批次 CSV、导入清单
  --rebuild-list 仅按现有批次 CSV + WorkBuddy 原始 CSV 重建 27 行导入清单（不写 media / 批次 CSV）

App 标签（阶段一规则）：只保留中文主题词；拒绝颜色词、作者/摄影师、水印、编号、英文/宣发语；
按 WorkBuddy 原顺序取前 4 个并去重。原始 CSV 不改，完整原始标签留在导入清单 workbuddy_raw_tags。
"""
import argparse
import csv
import json
import os
import re
import sys

from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from image_hash import (DEDUP_THRESHOLD, aspect_ok, hamming, image_size, phash64,
                       sha256_file)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media')
BATCH_DIR = os.path.join(ROOT, 'assets-local', 'batches')
LEGACY_CSVS = [
    os.path.join(ROOT, 'assets-local', 'base-51.csv'),
]

# 沿用 tools/add_local_batch.py 的既有压缩档，不改变其他图片的保存行为
EDGE = 1080
QUALITY = 68
THUMB_EDGE = 400
THUMB_QUALITY = 68

BATCH = 'w113-20261103'
BATCH_PREFIX = 'w113'
EXPECTED = 27
SRC_DIR = r'Z:\图片爬取\11.3'
WB_CSV = os.path.join(ROOT, 'docs', 'workbuddy-image-tags-final.csv')
LIST_CSV = os.path.join(ROOT, 'docs', '11.3-导入清单-2026-11-07.csv')
LIST_FIELDS = ['source_file', 'app_id', 'category', 'width', 'height', 'sha256', 'phash',
               'distance', 'workbuddy_raw_tags', 'app_tags', 'action']
BATCH_FIELDS = ['id', 'title', 'category', 'author', 'uploadTime', 'tags']

# 阶段一标签过滤：颜色字（保守：标签含任一颜色字即视为颜色词）
COLOR_CHARS = set('红橙黄绿青蓝紫粉黑白灰棕金银彩褐')
# 作者/摄影师、水印、编号、宣发/版式等非主题词
BAD_WORDS = ('摄影', '摄影师', '作者', '拍摄', '水印', '壁纸', '文字', '标语', '口号',
             '图片', '作品', '拥有今天', 'lucky day')
CJK_ONLY = re.compile(r'[\u4e00-\u9fff]+$')


def app_tags(raw_tags: str):
    """按阶段一规则从 WorkBuddy 3~8 个标签中取 1~4 个中文主题词"""
    try:
        tags = json.loads(raw_tags)
    except (ValueError, TypeError):
        return []
    out = []
    for tag in tags:
        t = str(tag).strip()
        if not t or not CJK_ONLY.match(t):
            continue
        if any(c in COLOR_CHARS for c in t):
            continue
        if any(w in t.lower() for w in BAD_WORDS):
            continue
        if t not in out:
            out.append(t)
    return out[:4]


def existing_catalog_ids(exclude_path):
    """当前 App 目录里其他主图的 id（base-51 + 其他批次，不含当前批次与个人照片）。
    当前批次不能作为“既有重复”阻挡自己，否则重复执行不幂等。"""
    ids = []
    paths = list(LEGACY_CSVS)
    if os.path.isdir(BATCH_DIR):
        for name in sorted(os.listdir(BATCH_DIR)):
            if not name.lower().endswith('.csv'):
                continue
            path = os.path.join(BATCH_DIR, name)
            if exclude_path is not None and os.path.abspath(path) == os.path.abspath(exclude_path):
                continue
            paths.append(path)
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, 'r', encoding='utf-8-sig', newline='') as fp:
            for row in csv.DictReader(fp):
                if row.get('id'):
                    ids.append(row['id'])
    return ids


def read_batch_ids(batch_path):
    if not os.path.exists(batch_path):
        return set()
    with open(batch_path, 'r', encoding='utf-8-sig', newline='') as fp:
        return set(r['id'] for r in csv.DictReader(fp) if r.get('id'))


def read_workbuddy(csv_path, folder='11.3'):
    rows = []
    with open(csv_path, 'r', encoding='utf-8-sig', newline='') as fp:
        for row in csv.DictReader(fp):
            if row.get('relative_path', '').startswith(folder + '/'):
                rows.append(row)
    return rows


def summarize(rows):
    counts = {}
    for r in rows:
        key = str(r.get('action', '')).split(':')[0]
        counts[key] = counts.get(key, 0) + 1
    return ', '.join('%s=%d' % (k, v) for k, v in sorted(counts.items()))


def atomic_write_csv(path, fields, rows):
    """先写 .tmp 再 os.replace，避免中断/异常时覆盖既有成功文件"""
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8-sig', newline='') as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
        fp.flush()
        os.fsync(fp.fileno())
    os.replace(tmp, path)


def write_list(rows):
    atomic_write_csv(LIST_CSV, LIST_FIELDS, rows)
    print('导入清单: %s（%d 行）' % (LIST_CSV, len(rows)))


def write_media(src, res_name):
    """与 add_local_batch.py 相同参数：主图长边 1080、缩略图长边 400"""
    dst_main = os.path.join(MEDIA, res_name + '.jpg')
    dst_thumb = os.path.join(MEDIA, res_name + '_thumb.jpg')
    with Image.open(src) as im:
        im = ImageOps.exif_transpose(im).convert('RGB')
        main = im.copy()
        scale = float(EDGE) / float(max(main.size))
        if scale < 1.0:
            main = main.resize(
                (max(1, int(main.size[0] * scale)), max(1, int(main.size[1] * scale))),
                Image.LANCZOS)
        main.save(dst_main, 'JPEG', quality=QUALITY, optimize=True, progressive=True)
        tscale = float(THUMB_EDGE) / float(max(main.size))
        thumb = main.resize(
            (max(1, int(main.size[0] * tscale)), max(1, int(main.size[1] * tscale)),
             ), Image.LANCZOS)
        thumb.save(dst_thumb, 'JPEG', quality=THUMB_QUALITY, optimize=True, progressive=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default=SRC_DIR)
    ap.add_argument('--csv', default=WB_CSV)
    ap.add_argument('--batch', default=BATCH)
    ap.add_argument('--prefix', default=BATCH_PREFIX)
    ap.add_argument('--expect', type=int, default=EXPECTED)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--rebuild-list', action='store_true')
    args = ap.parse_args()
    if args.dry_run and args.rebuild_list:
        print('--dry-run 与 --rebuild-list 不能同时使用')
        return 1

    if not os.path.isdir(args.src):
        print('源目录不存在: %s' % args.src)
        return 1
    if not os.path.exists(args.csv):
        print('WorkBuddy CSV 不存在: %s' % args.csv)
        return 1

    batch_path = os.path.join(BATCH_DIR, args.batch + '.csv')
    wb_rows = read_workbuddy(args.csv)
    print('WorkBuddy 11.3 行数: %d' % len(wb_rows))

    # 与源目录实际文件按文件名（relative_path 的 basename）精确匹配
    candidates = []
    rejected = []
    for row in wb_rows:
        rel = row['relative_path']
        name = rel.split('/')[-1]
        src = os.path.join(args.src, name)
        base = {
            'source_file': rel,
            'app_id': '',
            'category': row.get('category', ''),
            'width': row.get('width', ''),
            'height': row.get('height', ''),
            'sha256': '',
            'phash': '',
            'distance': '',
            'workbuddy_raw_tags': row.get('tags', ''),
            'app_tags': '',
        }
        if not os.path.exists(src):
            base['action'] = 'MISSING_SOURCE'
            rejected.append(base)
            continue
        try:
            real_w, real_h = image_size(src)
        except Exception as e:
            base['action'] = 'DECODE_FAIL:%s' % e
            rejected.append(base)
            continue
        base['width'], base['height'] = str(real_w), str(real_h)
        if not aspect_ok(real_w, real_h):
            base['action'] = 'REJECT_SIZE_RATIO'
            rejected.append(base)
            continue
        digest = sha256_file(src)
        ph = phash64(src)
        base['sha256'] = digest
        base['phash'] = ph
        tags = app_tags(row.get('tags', ''))
        base['app_tags'] = ','.join(tags)
        candidates.append({
            'row': row, 'base': base, 'src': src, 'name': name,
            'sha256': digest, 'phash': ph, 'size': os.path.getsize(src),
            'mtime': os.path.getmtime(src), 'width': real_w, 'height': real_h,
            'app_tags': tags,
        })

    print('实际存在且过尺寸+比例门槛: %d' % len(candidates))

    # 4) 候选内部去重：分辨率最高 → 体积最大 → mtime 最早 → 文件名
    def priority(c):
        return (-(c['width'] * c['height']), -c['size'], c['mtime'], c['name'])

    kept = []
    for cand in sorted(candidates, key=priority):
        dup_of = None
        for k in kept:
            if hamming(cand['phash'], k['phash']) <= DEDUP_THRESHOLD:
                dup_of = k
                break
        if dup_of is None:
            kept.append(cand)
        else:
            cand['base']['action'] = 'REJECT_INTERNAL_DUP'
            cand['base']['distance'] = str(hamming(cand['phash'], dup_of['phash']))
            rejected.append(cand['base'])
            print('  [内部重复] %s ≈ %s' % (cand['name'], dup_of['name']))

    # 5) 与其他既有主图比对（不含当前批次；缩略图 *_thumb 不参与）
    existing = []
    missing = 0
    for wid in existing_catalog_ids(batch_path):
        p = os.path.join(MEDIA, 'wp_%s.jpg' % wid)
        if not os.path.exists(p):
            missing += 1
            continue
        existing.append((wid, phash64(p)))
    print('既有主图参与比对: %d 张（缺失 %d）' % (len(existing), missing))

    batch_ids = read_batch_ids(batch_path)
    accepted = []
    already = []
    for cand in kept:
        stem = os.path.splitext(cand['name'])[0].lower()
        if not re.match(r'^[a-z0-9]+$', stem):
            print('资源名含非法字符，停止: %s' % stem)
            return 1
        app_id = '%s_%s' % (args.prefix, stem)
        res_name = 'wp_%s' % app_id
        cand['base']['app_id'] = app_id

        worst = 64
        hit = None
        for wid, ph in existing:
            d = hamming(cand['phash'], ph)
            if d < worst:
                worst = d
            if d <= DEDUP_THRESHOLD and hit is None:
                hit = (wid, d)
        if hit is not None:
            cand['base']['action'] = 'REJECT_EXISTING_DUP'
            cand['base']['distance'] = '%s:%d' % (hit[0], hit[1])
            rejected.append(cand['base'])
            print('  [与既有重复] %s ≈ %s d=%d' % (cand['name'], hit[0], hit[1]))
            continue

        cand['base']['distance'] = str(worst)
        if app_id in batch_ids:
            if os.path.exists(os.path.join(MEDIA, res_name + '.jpg')) and \
                    os.path.exists(os.path.join(MEDIA, res_name + '_thumb.jpg')):
                cand['base']['action'] = 'ALREADY_IMPORTED'
                already.append(cand)
            else:
                cand['base']['action'] = 'REJECT_BROKEN_STATE'
                rejected.append(cand['base'])
                print('  [批次有记录但资源缺失] %s' % app_id)
        else:
            accepted.append(cand)

    # 6) 只有正好 expect 条（新导入 + 已导入）才继续，不硬凑
    total_ready = len(accepted) + len(already)
    if total_ready != args.expect:
        print('合格 %d 条（新 %d + 已导入 %d），与预期 %d 不符：停止（未写任何文件）'
              % (total_ready, len(accepted), len(already), args.expect))
        print('未导入: %d 行（%s）' % (len(rejected), summarize(rejected)))
        return 2

    if args.dry_run:
        print('dry-run：零写入。计划新导入 %d 张，已导入 %d 张' % (len(accepted), len(already)))
        print('未导入: %d 行（%s）' % (len(rejected), summarize(rejected)))
        return 0

    if args.rebuild_list:
        if len(accepted) != 0:
            print('存在 %d 张尚未导入的候选：拒绝仅重建清单（避免伪造成功）' % len(accepted))
            return 2
        rows = sorted([c['base'] for c in already], key=lambda r: r['app_id'])
        for r in rows:
            r['action'] = 'IMPORT'
        write_list(rows)
        print('重建导入清单: %d 行，全部 IMPORT' % len(rows))
        return 0

    # 全部已导入：幂等成功，零写入（不改 media / 批次 CSV / 导入清单）
    if len(accepted) == 0:
        print('幂等：当前批次 %d 张已全部导入，资源/批次 CSV/导入清单均未改动' % len(already))
        print('未导入: %d 行（%s）' % (len(rejected), summarize(rejected)))
        return 0

    # 混合状态（部分已导入 + 部分新）：保守停止，避免写出半套文件
    if len(already) > 0:
        print('混合状态（已导入 %d / 新 %d）：停止，请人工检查' % (len(already), len(accepted)))
        return 2

    # 7) 首次导入：写资源 + 批次 CSV + 导入清单
    os.makedirs(MEDIA, exist_ok=True)
    os.makedirs(BATCH_DIR, exist_ok=True)
    batch_rows = []
    imported = []
    main_bytes = 0
    thumb_bytes = 0
    for cand in accepted:
        app_id = cand['base']['app_id']
        res_name = 'wp_%s' % app_id
        cand['base']['action'] = 'IMPORT'
        write_media(cand['src'], res_name)
        main_bytes += os.path.getsize(os.path.join(MEDIA, res_name + '.jpg'))
        thumb_bytes += os.path.getsize(os.path.join(MEDIA, res_name + '_thumb.jpg'))
        tags = cand['app_tags']
        title = '·'.join(tags[:2]) if tags else cand['row'].get('category', '')
        batch_rows.append({
            'id': app_id,
            'title': title,
            'category': cand['row'].get('category', ''),
            'author': '',
            'uploadTime': str(int(cand['mtime'] * 1000)),
            'tags': ','.join(tags),
        })
        imported.append(cand['base'])

    atomic_write_csv(batch_path, BATCH_FIELDS, batch_rows)
    print('批次清单: %s（%d 条）' % (batch_path, len(batch_rows)))
    write_list(sorted(imported, key=lambda r: r['app_id']))
    print('未导入: %d 行（%s）' % (len(rejected), summarize(rejected)))
    print('导入: %d 张' % len(accepted))
    print('主图 %.1f MB / 缩略图 %.1f MB' % (main_bytes / 1048576.0, thumb_bytes / 1048576.0))
    return 0


if __name__ == '__main__':
    sys.exit(main())
