# -*- coding: utf-8 -*-
"""由 seed_values.csv 推导 likeCount，量级与 view_count 一致（约 0.8%~3.2%）。"""
import csv
import random

SRC = r'e:\zeroone\tools\seed_out\seed-20261107\seed_values.csv'
DST = r'e:\zeroone\tools\seed_out\seed-20261107\like.sql'

rows = list(csv.DictReader(open(SRC, encoding='utf-8-sig')))
rng = random.Random('like-20261107')
lines = ['-- 由 tools/seed_out/seed-20261107 的 view_count 推导 likeCount（0.8%~3.2%）',
         'START TRANSACTION;']
nz = 0
for r in rows:
    v = int(r['view_count'])
    rate = 0.008 + 0.024 * (rng.random() ** 1.5)
    like = int(v * rate)
    if like > 0:
        nz += 1
    lines.append(
        "UPDATE wallpapers SET like_count=%d WHERE id=%s AND seed_batch='seed-20261107' AND like_count=0;"
        % (like, r['id']))
lines.append('COMMIT;')
open(DST, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('预计 likeCount>0 张数: %d / %d' % (nz, len(rows)))
print('写出:', DST)
