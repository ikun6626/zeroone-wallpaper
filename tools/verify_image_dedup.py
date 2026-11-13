# -*- coding: utf-8 -*-
"""
图片去重验收（本地 App 资源）

断言：
  1. 活跃主图（排除 *_thumb / 个人照片）SHA-256 完全重复组 = 0；
  2. 活跃主图 pHash ≤6 重复组 = 0；
  3. 11.3 导入的 27 张：与既有主图 pHash ≤6 = 0，内部重复 = 0；
  4. 导入清单 27 行、逐行 IMPORT、资源存在、尺寸/比例合格、app_tags 1~4 且无颜色/英文/作者/编号；
  5. 淘汰的 3 张主图 + 3 张缩略图不在 active media，且存在于 docs/dedup-quarantine/2026-11-07/。

用法：E:\\Anaconda\\python.exe tools\\verify_image_dedup.py
"""
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from image_hash import DEDUP_THRESHOLD, aspect_ok, hamming, image_size, phash64, ratio, sha256_file

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media')
ETS = os.path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'constants', 'LocalWallpapers.ets')
LIST_CSV = os.path.join(ROOT, 'docs', '11.3-导入清单-2026-11-07.csv')
QUARANTINE = os.path.join(ROOT, 'docs', 'dedup-quarantine', '2026-11-07',
                          'entry', 'src', 'main', 'resources', 'base', 'media')

DISCARDED = ['jofy88_fall_1051300_1920_1', 'w1462_1c7d482e29', 'w2004_160101601b']
KEPT = {'jofy88_fall_1051300_1920_1': 'jofy88_fall_1051300',
        'w1462_1c7d482e29': 'w1546_07bfd74f9c',
        'w2004_160101601b': 'w3474_28910b7791'}
EXPECTED_LEGACY = 280
EXPECTED_IMPORTED = 27

COLOR_CHARS = set('红橙黄绿青蓝紫粉黑白灰棕金银彩褐')
CJK_ONLY = re.compile(r'[\u4e00-\u9fff]+$')

results = []


def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    print('[%s] %s%s' % ('PASS' if ok else 'FAIL', name, ('  ' + detail) if detail else ''))
    return ok


def parse_catalog():
    with open(ETS, 'r', encoding='utf-8') as fp:
        text = fp.read()
    ids = re.findall(r"new Wallpaper\('([^']+)'", text)
    alias_m = re.search(r"static readonly DEDUP_ALIASES: Record<string, string> = \{(.+?)\};", text)
    aliases = dict(re.findall(r"'([^']+)': '([^']+)'", alias_m.group(1))) if alias_m else {}
    cats_m = re.search(r"static readonly CATEGORIES: string\[\] = \[(.+?)\];", text)
    cats = re.findall(r"'([^']+)'", cats_m.group(1)) if cats_m else []
    return ids, aliases, cats


def main():
    ok_all = True
    ids, aliases, cats = parse_catalog()
    catalog_ids = [i for i in ids if not i.startswith('my_')]
    personal = [i for i in ids if i.startswith('my_')]
    print('目录主图: %d（个人照片 %d）' % (len(catalog_ids), len(personal)))

    ok_all &= check('目录条目数 = 280 + 27', len(catalog_ids) == EXPECTED_LEGACY + EXPECTED_IMPORTED,
                    '实际 %d' % len(catalog_ids))
    ok_all &= check('DEDUP_ALIASES 与预期一致', aliases == KEPT, str(aliases))

    imported = [i for i in catalog_ids if i.startswith('w113_')]
    legacy = [i for i in catalog_ids if not i.startswith('w113_')]
    ok_all &= check('既有主图 = 280', len(legacy) == EXPECTED_LEGACY, '实际 %d' % len(legacy))
    ok_all &= check('11.3 导入主图 = 27', len(imported) == EXPECTED_IMPORTED, '实际 %d' % len(imported))

    # 资源存在性
    missing_main = [i for i in catalog_ids if not os.path.exists(os.path.join(MEDIA, 'wp_%s.jpg' % i))]
    missing_thumb = [i for i in catalog_ids if not os.path.exists(os.path.join(MEDIA, 'wp_%s_thumb.jpg' % i))]
    ok_all &= check('目录主图资源全部存在', not missing_main, ','.join(missing_main[:5]))
    ok_all &= check('目录缩略图资源全部存在', not missing_thumb, ','.join(missing_thumb[:5]))

    # 1) SHA + pHash 全量
    hashes = {}
    sha_groups = {}
    for i in catalog_ids:
        p = os.path.join(MEDIA, 'wp_%s.jpg' % i)
        hashes[i] = phash64(p)
        sha_groups.setdefault(sha256_file(p), []).append(i)
    sha_dup = [v for v in sha_groups.values() if len(v) > 1]
    ok_all &= check('SHA-256 完全重复组 = 0', not sha_dup, str(sha_dup))

    pairs = []
    for idx, a in enumerate(catalog_ids):
        for b in catalog_ids[idx + 1:]:
            d = hamming(hashes[a], hashes[b])
            if d <= DEDUP_THRESHOLD:
                pairs.append((d, a, b))
    ok_all &= check('活跃主图 pHash ≤6 组 = 0', not pairs, str(pairs))

    # 2) 11.3 导入图与既有图 / 自身
    cross = []
    for a in imported:
        for b in legacy:
            d = hamming(hashes[a], hashes[b])
            if d <= DEDUP_THRESHOLD:
                cross.append((d, a, b))
    ok_all &= check('11.3 与既有主图 pHash ≤6 = 0', not cross, str(cross))
    internal = []
    for idx, a in enumerate(imported):
        for b in imported[idx + 1:]:
            d = hamming(hashes[a], hashes[b])
            if d <= DEDUP_THRESHOLD:
                internal.append((d, a, b))
    ok_all &= check('11.3 内部 pHash ≤6 = 0', not internal, str(internal))

    # 3) 导入清单
    with open(LIST_CSV, 'r', encoding='utf-8-sig', newline='') as fp:
        rows = list(csv.DictReader(fp))
    ok_all &= check('导入清单 27 行', len(rows) == EXPECTED_IMPORTED, '实际 %d' % len(rows))
    ok_all &= check('导入清单逐行 action=IMPORT', all(r['action'] == 'IMPORT' for r in rows),
                    str(sorted(set(r['action'] for r in rows))))
    ok_all &= check('导入清单 app_id 与目录一致',
                    set(r['app_id'] for r in rows) == set(imported))

    bad_size, bad_tags, bad_files, bad_cat = [], [], [], []
    for r in rows:
        app_id = r['app_id']
        p = os.path.join(MEDIA, 'wp_%s.jpg' % app_id)
        if not os.path.exists(p):
            bad_files.append(app_id)
            continue
        w, h = int(r['width']), int(r['height'])
        if not aspect_ok(w, h):
            bad_size.append('%s %dx%d' % (app_id, w, h))
        out_w, out_h = image_size(p)
        if not (9.0 / 21.0 <= ratio(out_w, out_h) <= 9.0 / 16.0):
            bad_size.append('%s 输出比例 %.3f' % (app_id, ratio(out_w, out_h)))
        tags = [t for t in r['app_tags'].split(',') if t]
        if not (1 <= len(tags) <= 4) or len(tags) != len(set(tags)):
            bad_tags.append('%s n=%d' % (app_id, len(tags)))
        for t in tags:
            if not CJK_ONLY.match(t) or any(c in COLOR_CHARS for c in t) \
                    or any(x in t for x in ('摄影', '作者', '水印', '壁纸', '文字')):
                bad_tags.append('%s:%s' % (app_id, t))
        if r['category'] not in cats:
            bad_cat.append('%s:%s' % (app_id, r['category']))
    ok_all &= check('导入清单资源存在', not bad_files, ','.join(bad_files[:5]))
    ok_all &= check('导入清单尺寸/比例合格', not bad_size, ';'.join(bad_size[:5]))
    ok_all &= check('app_tags 1~4 且中文主题词合规', not bad_tags, ';'.join(bad_tags[:5]))
    ok_all &= check('导入类目都在 CATEGORIES', not bad_cat, ';'.join(bad_cat[:5]))

    # 4) 淘汰文件
    still_active = [i for i in DISCARDED
                    if os.path.exists(os.path.join(MEDIA, 'wp_%s.jpg' % i))
                    or os.path.exists(os.path.join(MEDIA, 'wp_%s_thumb.jpg' % i))]
    ok_all &= check('淘汰 3 组不在 active media', not still_active, ','.join(still_active))

    quar_missing = []
    for i in DISCARDED:
        for suffix in ('', '_thumb'):
            p = os.path.join(QUARANTINE, 'wp_%s%s.jpg' % (i, suffix))
            if not os.path.exists(p):
                quar_missing.append(os.path.basename(p))
    ok_all &= check('淘汰文件在 quarantine 完整', not quar_missing, ','.join(quar_missing))

    keep_missing = [i for i in KEPT.values() if not os.path.exists(os.path.join(MEDIA, 'wp_%s.jpg' % i))]
    ok_all &= check('3 组保留文件存在', not keep_missing, ','.join(keep_missing))

    # 5) media 统计
    mains_all = [f for f in os.listdir(MEDIA) if f.endswith('.jpg') and not f.endswith('_thumb.jpg')]
    thumbs = [f for f in os.listdir(MEDIA) if f.endswith('_thumb.jpg')]
    print('media: 主图 %d（素材 %d + 个人照片 %d）/ 缩略图 %d'
          % (len(mains_all), len(catalog_ids), len(personal), len(thumbs)))
    ok_all &= check('media 主图 = 307 + 12 个人照片', len(mains_all) == len(catalog_ids) + len(personal),
                    '实际 %d' % len(mains_all))

    print('')
    print('结果: %d 项，通过 %d，失败 %d' % (len(results), sum(1 for _, ok, _ in results if ok),
                                          sum(1 for _, ok, _ in results if not ok)))
    return 0 if ok_all else 1


if __name__ == '__main__':
    sys.exit(main())
