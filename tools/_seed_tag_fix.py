# -*- coding: utf-8 -*-
# 修正：把 assets-local csv 的原始主题标签合回种子行（csv 标签 ∪ 分类/主色）
import csv
import io
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def esc(s: str) -> str:
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


csv_tags = {}
for p in ['assets-local/base-51.csv', 'assets-local/batches/scenery.csv']:
    path = os.path.join(ROOT, p)
    if not os.path.exists(path):
        continue
    for r in csv.DictReader(io.open(path, 'r', encoding='utf-8-sig', newline='')):
        rid = (r.get('id') or '').strip()
        if rid:
            csv_tags[rid] = (r.get('tags') or '').strip()
print('csv 主题标签条目', len(csv_tags))

rows = list(csv.DictReader(io.open(os.path.join(ROOT, 'tools/metadata_draft.csv'),
                                   'r', encoding='utf-8-sig', newline='')))
stmts = []
touched = 0
for r in rows:
    lid = (r.get('local_id') or '').strip()
    if not lid or lid not in csv_tags or not csv_tags[lid]:
        continue
    merged = []
    for t in [x.strip() for x in csv_tags[lid].replace('，', ',').split(',') if x.strip()]:
        if t not in merged:
            merged.append(t)
    for t in [x.strip() for x in (r.get('suggested_tags') or '').split(',') if x.strip()]:
        if t not in merged:
            merged.append(t)
    sid = r['server_id']
    touched += 1
    stmts.append(f'DELETE FROM `_TagToWallpaper` WHERE `B` = {sid};')
    for t in merged:
        stmts.append(f'INSERT IGNORE INTO `tags` (`name`, `created_at`) VALUES ({esc(t)}, NOW());')
        stmts.append(f'INSERT IGNORE INTO `_TagToWallpaper` (`A`, `B`) '
                     f'SELECT `id`, {sid} FROM `tags` WHERE `name` = {esc(t)};')

out = os.path.join(ROOT, 'tools/metadata_seed_fix.sql')
with io.open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write('-- 修正：种子行主题标签回填（csv 原始标签 ∪ 分类/主色），幂等\n')
    f.write('\n'.join(stmts) + '\n')
print(f'修正 SQL：{len(stmts)} 条语句，覆盖 {touched} 行 -> {out}')
