#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ZeroOne 种子数据（viewCount / downloadCount）生成与清除
=======================================================

用途：在真实用户量不足、推荐流没有曝光分母的阶段，给现有「唯一图集」灌入
一条可识别的长尾基线，使推荐流的排序、角标、看板能被真实验证。

设计口径（与 PROJECT.md 第 3 节一致）
- 浏览 viewCount：帕累托长尾 x_m=25、alpha=1.35，硬上限 2000
- 保存 downloadCount：view × 保存率，保存率 = 3% + 9%·u^1.8（均值约 6.2%，落在 3%~12%）
- 风格组：先乘一个组级系数 lognormal(sigma=0.45)，再乘单图抖动 lognormal(sigma=0.18)
  → 组与组之间有量级差，组内也有差异，不会出现「全库同一量级」
- 上架时间：过去 90 天（u^1.6 偏向近期），用于新品加成与「上架天数」兜底
- 标记：is_seed=1 + seed_batch='<批次名>'，可一键清除、可回滚到原值

不依赖数据库、不依赖第三方库。输入是一份从后台/线上导出的 JSON：
  [{"id":1,"style":"landscape","createdAt":"2026-09-01","viewCount":0,"downloadCount":0}, ...]

用法
  python tools/zeroone_seed_data.py generate --input wallpapers.json --batch seed-20261107
  python tools/zeroone_seed_data.py preview  --input wallpapers.json --batch seed-20261107
  python tools/zeroone_seed_data.py clear    --csv tools/seed_out/seed-20261107/seed_values.csv

输出（默认 tools/seed_out/<batch>/）
  00_seed_schema.sql   新增 is_seed / seed_batch 两列（幂等）
  seed_values.csv      最终数值 + 原值（orig_*）快照
  apply.sql            幂等 UPDATE，可重复执行
  clear.sql            一键清除：恢复 orig_*、清空 is_seed / seed_batch
  summary.json         分布统计（供看板/验收核对）
"""

import argparse
import csv
import json
import math
import os
import random
import statistics
import sys
from datetime import datetime, timedelta

# ---------------- 分布参数（改参数必须同步改文档 §5A.8） ----------------
PARETO_XM = 25.0        # 尾部起点：绝大多数图至少 25 次浏览
PARETO_ALPHA = 1.35     # alpha 越小尾巴越长；1.35 使 P(>2000)≈0.3%
VIEW_CAP = 2000         # 浏览硬上限
VIEW_MIN = 20           # 下限，避免出现 0 浏览 + 0 保存的死图
SAVE_RATE_BASE = 0.03   # 保存率下限
SAVE_RATE_SPAN = 0.09   # 保存率跨度 → 上限 12%
SAVE_RATE_POW = 1.8     # 偏向低保存率（多数图 3%~6%，少数 10%~12%）
STYLE_SIGMA = 0.45      # 组级系数（对数正态）
ITEM_SIGMA = 0.18       # 单图抖动（对数正态）
SPREAD_DAYS = 90        # 上架时间打散范围
RECENT_BIAS = 1.6       # >1 时偏向近期上架

# ===== 分组权重（2026-11-07 用户要求：11.3 批次抬高、每日精选抬高、其他正常）=====
# 权重只放大/缩小该组的 viewCount，保存率仍按 3%~12% 独立抽样，不破坏口径。
# 同名批次优先判定：11.3 > 每日精选来源 > 其他（不叠加，避免出现一眼假的天文数字）。
GROUP_SCALES = {
    'batch113': 3.0,    # 11.3 批次：中位数约为其他组的 1.8~1.9 倍
    'daily': 2.8,       # 每日精选来源：按用户验收口径调到约 3.5 倍（原默认 2.2 只有 2.8 倍）
    'other': 1.0,       # 其他：保持长尾（中位数 25 起）
}
BATCH113_DATE = '2026-11-03'

DEFAULT_STYLE_COUNT = 8


def pareto(rng, xm, alpha):
    u = rng.random()
    return xm * (1.0 - u) ** (-1.0 / alpha)


def lognormal(rng, sigma):
    return math.exp(rng.gauss(0.0, sigma))


def style_key(item):
    s = str(item.get('style') or '').strip()
    if s:
        return s
    # 没有风格组时按 id 稳定分桶（只作占位，正式导入应带 style）
    return 'g%d' % (int(item['id']) % DEFAULT_STYLE_COUNT + 1)


def group_key(item):
    """分组：batch113（11.3 批次）> daily（每日精选来源）> other。

    判定依据（按优先级）：
      1. publishedAt / createdAt 的日期等于 2026-11-03 → batch113；
      2. source / album / style / tags / title 里出现 daily 或「每日精选」→ daily；
      3. 其余 → other。
    同一张图只归一个组，权重不叠加。
    """
    d = str(item.get('publishedAt') or item.get('createdAt') or '')
    if d[:10] == BATCH113_DATE:
        return 'batch113'
    raw = ' '.join(str(item.get(k) or '') for k in
                   ('source', 'album', 'style', 'tags', 'title')).lower()
    if 'daily' in raw or '每日精选' in raw:
        return 'daily'
    return 'other'


def build_rows(items, batch, seed):
    rng = random.Random('%s|%s' % (batch, seed))
    styles = sorted({style_key(x) for x in items})
    style_scale = {}
    for s in styles:
        # 组级系数截断在 [0.45, 2.2]，避免某一组整体过小/过大
        style_scale[s] = min(2.2, max(0.45, lognormal(rng, STYLE_SIGMA)))

    rows = []
    for it in items:
        wid = int(it['id'])
        s = style_key(it)
        g = group_key(it)
        # 非 other 组不叠风格系数：否则「11.3 抬高」会被风格随机系数吃掉，
        # 导致小样本下均值不可解释；other 仍保留风格差异。
        style_mult = style_scale[s] if g == 'other' else 1.0
        v = (pareto(rng, PARETO_XM, PARETO_ALPHA) * style_mult
             * lognormal(rng, ITEM_SIGMA) * GROUP_SCALES[g])
        v = int(round(min(VIEW_CAP, max(VIEW_MIN, v))))

        rate = SAVE_RATE_BASE + SAVE_RATE_SPAN * (rng.random() ** SAVE_RATE_POW)
        lo = max(1, int(math.ceil(v * SAVE_RATE_BASE)))
        hi = max(lo, int(math.floor(v * (SAVE_RATE_BASE + SAVE_RATE_SPAN))))
        d = max(lo, min(hi, int(round(v * rate))))

        if g == 'batch113':
            # 11.3 批次必须落在 2026-11-03：首页「最近」按上架时间倒序，
            # 不能被 90 天打散挪走（否则种子灌完「最近」又看不到这批图）
            pub = '%s %02d:%02d:%02d' % (BATCH113_DATE, rng.randint(0, 23),
                                         rng.randint(0, 59), rng.randint(0, 59))
        else:
            days_ago = int(round(SPREAD_DAYS * (rng.random() ** RECENT_BIAS)))
            created = datetime.now() - timedelta(days=days_ago, seconds=rng.randint(0, 86399))
            pub = created.strftime('%Y-%m-%d %H:%M:%S')

        rows.append({
            'id': wid,
            'style_group': s,
            'group': g,
            'view_count': v,
            'download_count': d,
            'published_at': pub,
            'is_seed': 1,
            'seed_batch': batch,
            'orig_view': int(it.get('viewCount') or 0),
            'orig_download': int(it.get('downloadCount') or 0),
            'orig_published_at': str(it.get('publishedAt') or ''),
        })
    return rows


def stats(rows):
    views = [r['view_count'] for r in rows]
    downs = [r['download_count'] for r in rows]
    rates = [r['download_count'] / r['view_count'] for r in rows]
    by_style = {}
    by_group = {}
    for r in rows:
        by_style.setdefault(r['style_group'], []).append(r['view_count'])
        by_group.setdefault(r['group'], []).append(r['view_count'])
    style_means = {k: statistics.mean(v) for k, v in by_style.items()}
    group_means = {k: round(statistics.mean(v), 1) for k, v in by_group.items()}
    group_medians = {k: int(statistics.median(v)) for k, v in by_group.items()}
    q = statistics.quantiles(views, n=10) if len(views) >= 10 else []
    return {
        'count': len(rows),
        'group_counts': {k: len(v) for k, v in by_group.items()},
        'group_view_means': group_means,
        'group_view_medians': group_medians,
        'view_min': min(views), 'view_p50': int(statistics.median(views)),
        'view_p90': int(q[8]) if q else None,
        'view_max': max(views),
        'view_mean': round(statistics.mean(views), 1),
        'download_min': min(downs), 'download_p50': int(statistics.median(downs)),
        'download_max': max(downs),
        'save_rate_mean': round(statistics.mean(rates), 4),
        'save_rate_min': round(min(rates), 4),
        'save_rate_max': round(max(rates), 4),
        'style_groups': len(by_style),
        'style_mean_min': round(min(style_means.values()), 1),
        'style_mean_max': round(max(style_means.values()), 1),
    }


def validate(st):
    errs = []
    if st['count'] < 1:
        errs.append('样本为空')
    if st['view_max'] > VIEW_CAP:
        errs.append('view_max 超过上限 %d' % VIEW_CAP)
    if not (0.03 <= st['save_rate_mean'] <= 0.12):
        errs.append('整体保存率 %.4f 不在 3%%~12%%' % st['save_rate_mean'])
    if st['save_rate_min'] < 0.03 or st['save_rate_max'] > 0.12:
        errs.append('单图保存率越界：%.4f ~ %.4f' % (st['save_rate_min'], st['save_rate_max']))
    if st['count'] >= 100 and (st['style_mean_max'] / max(1.0, st['style_mean_min'])) < 1.3:
        errs.append('风格组均值差异不足 1.3 倍，可能出现全库同量级')
    if st['count'] >= 100 and st['view_p90'] < st['view_p50'] * 2:
        errs.append('长尾不明显：p90 不到中位数 2 倍')
    # 分组权重验收：用中位数（小样本下均值会被长尾单点主导）
    gmed = st.get('group_view_medians') or {}
    if 'batch113' in gmed and 'other' in gmed and gmed['batch113'] < gmed['other'] * 1.4:
        errs.append('11.3 批次中位数未达到其他组的 1.4 倍：%d vs %d'
                    % (gmed['batch113'], gmed['other']))
    if 'daily' in gmed and 'other' in gmed and gmed['daily'] < gmed['other'] * 1.2:
        errs.append('每日精选中位数未达到其他组的 1.2 倍：%d vs %d'
                    % (gmed['daily'], gmed['other']))
    return errs


def read_items(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        data = json.load(f)
    if isinstance(data, dict):
        data = data.get('list') or data.get('items') or []
    if not isinstance(data, list) or not data:
        raise SystemExit('输入 JSON 必须是数组（或 {list:[...]}），且不能为空')
    seen = set()
    out = []
    for x in data:
        if 'id' not in x:
            raise SystemExit('每条记录缺 id 字段')
        wid = int(x['id'])
        if wid in seen:
            continue
        seen.add(wid)
        out.append(x)
    return out


def write_outputs(rows, batch, outdir, items):
    os.makedirs(outdir, exist_ok=True)
    st = stats(rows)

    csv_path = os.path.join(outdir, 'seed_values.csv')
    cols = ['id', 'style_group', 'group', 'view_count', 'download_count', 'published_at',
            'is_seed', 'seed_batch', 'orig_view', 'orig_download', 'orig_published_at']
    with open(csv_path, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    schema_sql = """-- ZeroOne 种子数据：结构（MySQL 8；只执行一次，列已存在则跳过该行）
ALTER TABLE wallpapers ADD COLUMN is_seed TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE wallpapers ADD COLUMN seed_batch VARCHAR(32) NOT NULL DEFAULT '';
CREATE INDEX idx_wallpapers_seed_batch ON wallpapers (seed_batch);
"""
    with open(os.path.join(outdir, '00_seed_schema.sql'), 'w', encoding='utf-8') as f:
        f.write(schema_sql)

    with open(os.path.join(outdir, 'apply.sql'), 'w', encoding='utf-8') as f:
        f.write('-- 由 tools/zeroone_seed_data.py 生成；幂等 UPDATE，可整批重跑\n')
        f.write('-- 只命中「本批次且尚未被标记」的行，避免覆盖真实用户增长\n')
        f.write('START TRANSACTION;\n')
        for r in rows:
            f.write(
                "UPDATE wallpapers SET view_count=%d, download_count=%d, published_at='%s', "
                "is_seed=1, seed_batch='%s' WHERE id=%d AND is_seed=0;\n"
                % (r['view_count'], r['download_count'], r['published_at'], batch, r['id'])
            )
        f.write('COMMIT;\n')

    with open(os.path.join(outdir, 'clear.sql'), 'w', encoding='utf-8') as f:
        f.write('-- 一键清除：恢复到生成前快照（orig_*），并去掉种子标记\n')
        f.write('START TRANSACTION;\n')
        for r in rows:
            f.write(
                "UPDATE wallpapers SET view_count=%d, download_count=%d, "
                "published_at=%s, is_seed=0, seed_batch='' "
                "WHERE id=%d AND seed_batch='%s';\n"
                % (
                    r['orig_view'], r['orig_download'],
                    ("'%s'" % r['orig_published_at']) if r['orig_published_at'] else 'NULL',
                    r['id'], batch,
                )
            )
        f.write('COMMIT;\n')

    with open(os.path.join(outdir, 'summary.json'), 'w', encoding='utf-8') as f:
        json.dump({'batch': batch, 'generated_at': datetime.now().isoformat(timespec='seconds'),
                   'input_count': len(items), 'stats': st}, f, ensure_ascii=False, indent=2)
    return st, csv_path


def cmd_generate(args):
    items = read_items(args.input)
    rows = build_rows(items, args.batch, args.seed)
    outdir = args.outdir or os.path.join('tools', 'seed_out', args.batch)
    st, csv_path = write_outputs(rows, args.batch, outdir, items)
    errs = validate(st)
    print(json.dumps(st, ensure_ascii=False, indent=2))
    print('输出目录:', os.path.abspath(outdir))
    if errs:
        print('!! 校验失败：')
        for e in errs:
            print('   -', e)
        return 1
    print('校验通过：长尾 / 3%%~12%% / 上限 %d / 组间差异 均满足' % VIEW_CAP)
    return 0


def cmd_preview(args):
    items = read_items(args.input)
    rows = build_rows(items, args.batch, args.seed)
    st = stats(rows)
    print(json.dumps(st, ensure_ascii=False, indent=2))
    errs = validate(st)
    if errs:
        print('!! 预览校验失败：', '；'.join(errs))
        return 1
    print('预览通过（未写文件）')
    return 0


def cmd_clear(args):
    with open(args.csv, 'r', encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))
    batch = rows[0]['seed_batch'] if rows else ''
    outdir = os.path.dirname(os.path.abspath(args.csv))
    path = os.path.join(outdir, 'clear.sql')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('-- 一键清除批次 %s（恢复 orig_* 并去掉种子标记）\n' % batch)
        f.write('START TRANSACTION;\n')
        for r in rows:
            orig_pub = r['orig_published_at']
            f.write(
                "UPDATE wallpapers SET view_count=%d, download_count=%d, published_at=%s, "
                "is_seed=0, seed_batch='' WHERE id=%d AND seed_batch='%s';\n"
                % (int(r['orig_view']), int(r['orig_download']),
                   ("'%s'" % orig_pub) if orig_pub else 'NULL',
                   int(r['id']), r['seed_batch'])
            )
        f.write('COMMIT;\n')
        f.write("-- 校验：SELECT COUNT(*) FROM wallpapers WHERE seed_batch='%s';  -- 必须为 0\n" % batch)
    print('已生成', path, '共', len(rows), '行；执行后 seed_batch 应为空')
    return 0


def main():
    p = argparse.ArgumentParser(description='ZeroOne 种子数据生成 / 预览 / 清除')
    sub = p.add_subparsers(dest='cmd', required=True)

    g = sub.add_parser('generate', help='生成 CSV + apply.sql + clear.sql')
    g.add_argument('--input', required=True, help='壁纸导出 JSON')
    g.add_argument('--batch', default='seed-' + datetime.now().strftime('%Y%m%d'), help='批次名')
    g.add_argument('--seed', default='zeroone', help='随机种子（同批次可复现）')
    g.add_argument('--outdir', default=None, help='输出目录，默认 tools/seed_out/<batch>/')

    v = sub.add_parser('preview', help='只打印分布统计，不落盘')
    v.add_argument('--input', required=True)
    v.add_argument('--batch', default='seed-preview')
    v.add_argument('--seed', default='zeroone')

    c = sub.add_parser('clear', help='按 seed_values.csv 生成 clear.sql')
    c.add_argument('--csv', required=True)

    args = p.parse_args()
    return {'generate': cmd_generate, 'preview': cmd_preview, 'clear': cmd_clear}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
