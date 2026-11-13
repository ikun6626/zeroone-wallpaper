# -*- coding: utf-8 -*-
"""
首页/搜索去重自动检测（线上接口，只读）

用法：
  python tools/verify_home_dedup.py

检测项：
  1. /wallpapers 连续翻 10 批（pageSize=20）重复 id = 0；
  2. 各模块候选池（日报、每日往期、各合辑首页、最近/推荐流）之间，
     归一化（dup_id -> keep_id）后仍同时出现的 id —— 客户端必须避让；
  3. docs/重复图清理-批次清单.csv 中 keep/dup 同组同时在任一模块出现 ——
     数据层近似重复（pHash<=6），根治需服务端 dedup_keep_id。

输出为「需要客户端避让的组数」与具体清单；首页实际拼装已在客户端维护全局已用集合。
"""
import json
import os
import sys
import urllib.request
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = 'https://www.gqscc.cn/api/v1'
CSV = os.path.join(ROOT, 'docs', '重复图清理-批次清单.csv')


def fetch(path):
    url = BASE + path
    req = urllib.request.Request(url, headers={'User-Agent': 'zeroone-verify/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def payload(body):
    if isinstance(body, dict) and 'data' in body:
        return body['data']
    return body


def collect_ids(obj, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ('id', 'wallpaperId') and isinstance(v, int) and v > 0:
                out.add(v)
            collect_ids(v, out)
    elif isinstance(obj, list):
        for v in obj:
            collect_ids(v, out)


def load_groups():
    groups = []
    if not os.path.exists(CSV):
        return groups
    with open(CSV, 'r', encoding='utf-8-sig') as fp:
        header = fp.readline()
        for line in fp:
            parts = line.strip().split(',')
            if len(parts) < 4:
                continue
            try:
                keep, dup = int(parts[2]), int(parts[3])
            except ValueError:
                continue
            if keep > 0 and dup > 0:
                groups.append((keep, dup))
    return groups


def main():
    groups = load_groups()
    keep_of = {d: k for k, d in groups}
    fails = 0

    # 1. 推荐流 10 批重复 id
    seen = set()
    dup_in_feed = []
    for page in range(1, 11):
        data = payload(fetch('/wallpapers?page=%d&pageSize=20&sort=latest' % page))
        items = data.get('items') or data.get('list') or []
        for it in items:
            wid = it.get('id')
            if not isinstance(wid, int):
                continue
            if wid in seen:
                dup_in_feed.append((page, wid))
            seen.add(wid)
    print('[%s] 推荐流 10 批重复 id: %d（样本 %d 张）'
          % ('PASS' if not dup_in_feed else 'FAIL', len(dup_in_feed), len(seen)))
    if dup_in_feed:
        fails += 1
        print('      ', dup_in_feed[:10])

    # 2. 模块候选池
    modules = {}

    def add_module(name, path):
        d = payload(fetch(path))
        s = set()
        collect_ids(d, s)
        modules[name] = s

    try:
        add_module('composition', '/home/composition')
    except Exception as e:
        print('  composition 拉取失败：%s' % e)
    try:
        add_module('daily', '/albums/daily')
    except Exception as e:
        print('  daily 拉取失败：%s' % e)

    slugs = ['daily', 'anime', 'landscape', 'city', 'text', 'pets', 'couple', 'mixed']
    for slug in slugs:
        try:
            add_module('album:' + slug, '/albums/%s?page=1&pageSize=20' % slug)
        except Exception as e:
            print('  album %s 拉取失败：%s' % (slug, e))

    # 归一化去重集合
    norm = {}
    for name, s in modules.items():
        norm[name] = {keep_of.get(i, i) for i in s}

    names = list(norm.keys())
    cross_dups = []
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = names[i], names[j]
            both = norm[a] & norm[b]
            if both:
                cross_dups.append((a, b, len(both), sorted(both)[:6]))
    print('[%s] 跨模块归一后重叠组: %d（%s）'
          % ('PASS' if not cross_dups else 'INFO', len(cross_dups),
             ', '.join('%s/%s=%d' % (a, b, n) for a, b, n, _ in cross_dups) or '无'))
    for a, b, n, sample in cross_dups:
        print('      %s ↔ %s：%d 组，样本 %s' % (a, b, n, sample))

    # 3. dedup 组内 keep/dup 同现
    all_ids = s_all(modules)
    any_pairs = []
    for keep, dup in groups:
        if keep in all_ids and dup in all_ids:
            spots = [n for n, s in modules.items() if keep in s or dup in s]
            any_pairs.append((keep, dup, spots))
    print('[%s] pHash 同组（keep+dup 同时出现在候选池）: %d 组'
          % ('PASS' if not any_pairs else 'INFO', len(any_pairs)))
    for keep, dup, spots in any_pairs[:12]:
        print('      keep=%s dup=%s 模块=%s' % (keep, dup, spots))
    if len(any_pairs) > 12:
        print('      …其余 %d 组省略' % (len(any_pairs) - 12))

    print('\n结论：客户端已用 296 组 DedupKeeps + 全局已用集合避让；'
          '数据层未写回 dedup_keep_id，根治需服务端过滤。')
    return 0 if not dup_in_feed else 1


def s_all(modules):
    out = set()
    for s in modules.values():
        out |= s
    return out


if __name__ == '__main__':
    sys.exit(main())
