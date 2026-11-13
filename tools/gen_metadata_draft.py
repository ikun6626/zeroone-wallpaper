# -*- coding: utf-8 -*-
"""
gen_metadata_draft.py —— 壁纸元数据治理·初稿生成器（2026-10-25 第三批）

背景：线上 1598 张壁纸 tags 全空、标题多为内部编号（如「风景-00434087」），
导致 App 关键词搜索/标签筛选永远空转（CURRENT-STATE P1）。本脚本半自动生成
元数据初稿，人工复核后由 apply_metadata.py 导入数据库。

初稿来源（按优先级合并）：
  1. assets-local/base-51.csv（及 batches/*.csv，同格式）：51 张种子图有规范的
     中文标题与标签，按「本地目录 id」与线上 description 字段匹配回填；
  2. 图片文件名关键词字典（sunset→日落/夕阳、cat→猫 ……）：从 imageUrl 文件名
     提取英文 token 翻译成中文标签；
  3. 分类名 + 主色桶：天然可作标签。

用法：
  python tools/gen_metadata_draft.py [--out tools/metadata_draft.csv]
  python tools/gen_metadata_draft.py [--base https://www.gqscc.cn/api/v1]

产物 CSV 列：
  server_id, local_id, current_title, suggested_title, suggested_tags,
  category, dominant_color, orientation, width, height, image_url,
  reviewed_title, reviewed_tags   ← 人工只填这两列（留空=采纳初稿，填「-」=跳过该行）

注意：本机若有代理（Clash 等），requests 需 trust_env=False —— 脚本已处理。
"""
import argparse
import csv
import io
import json
import os
import re
import sys
import urllib.request

DEFAULT_BASE = 'https://www.gqscc.cn/api/v1'
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PAGE_SIZE = 50

# 文件名英文 token → 中文标签（词表可持续补充；大小写不敏感，命中即加）
KEYWORD_DICT = {
    'sunset': ['日落', '夕阳'], 'sunrise': ['日出'], 'night': ['夜景'], 'star': ['星空'],
    'starry': ['星空'], 'milky': ['银河'], 'northern': ['极光'], 'lights': ['极光'],
    'mountain': ['山', '山脉'], 'hill': ['丘陵'], 'lake': ['湖'], 'river': ['河流'],
    'sea': ['海'], 'ocean': ['海'], 'beach': ['海滩'], 'forest': ['森林'], 'tree': ['树'],
    'wood': ['森林'], 'field': ['田野'], 'meadow': ['草地'], 'grass': ['草地'],
    'flower': ['花'], 'autumn': ['秋'], 'fall': ['秋'], 'winter': ['冬'], 'snow': ['雪'],
    'spring': ['春'], 'summer': ['夏'], 'sky': ['天空'], 'cloud': ['云'],
    'cat': ['猫'], 'kitten': ['猫'], 'dog': ['狗'], 'puppy': ['狗'], 'pup': ['狗'],
    'animal': ['动物'], 'bird': ['鸟'], 'horse': ['马'], 'rabbit': ['兔'],
    'japan': ['日本'], 'airplane': ['航班'], 'plane': ['飞机'], 'road': ['道路'],
    'bridge': ['桥'], 'city': ['城市'], 'building': ['建筑'], 'architecture': ['建筑'],
    'street': ['街道'], 'lighthouse': ['灯塔'], 'lava': ['岩浆'], 'volcano': ['火山'],
    'desert': ['沙漠'], 'island': ['岛'], 'waterfall': ['瀑布'], 'canyon': ['峡谷'],
    'minimal': ['极简'], 'abstract': ['抽象'], 'painting': ['插画'], 'illustration': ['插画'],
    'macro': ['微距'], 'portrait': ['人像'], 'food': ['美食'], 'coffee': ['咖啡'],
    'leaf': ['叶子'], 'green': ['绿'], 'blue': ['蓝'], 'pink': ['粉'],
}

# 标题生成时去掉这些"编号类" token（纯数字、下划线分隔的站点编号）
NUMBER_TOKEN = re.compile(r'^\d+$')

CJK_RANGE = ((0x4E00, 0x9FFF), (0x3400, 0x4DBF))


def is_cjk_name(name: str) -> bool:
    """与 App AlbumsApi.isValidColorName 同规则：1~4 个汉字才算有效主色名"""
    if not name or len(name) > 4:
        return False
    return all(any(lo <= ord(c) <= hi for lo, hi in CJK_RANGE) for c in name)


def http_get_json(url: str):
    req = urllib.request.Request(url, headers={'User-Agent': 'zeroone-metadata-tool/1.0'})
    with urllib.request.urlopen(req, timeout=30) as resp:  # no proxy: 环境代理由 opener 绕过
        return json.loads(resp.read().decode('utf-8'))


def fetch_all_wallpapers(base: str):
    """分页拉取全部已发布壁纸（公开接口，响应信封 {code,message,data}）"""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 绕过本机代理
    urllib.request.install_opener(opener)
    rows, page = [], 1
    while True:
        url = f'{base}/wallpapers?page={page}&pageSize={PAGE_SIZE}&sort=latest'
        data = http_get_json(url).get('data') or {}
        batch = data.get('list') or []
        rows.extend(batch)
        print(f'  拉取第 {page} 页：{len(batch)} 条（累计 {len(rows)}）')
        if not data.get('hasMore') or len(batch) < PAGE_SIZE:
            break
        page += 1
    return rows


def load_local_csv_titles():
    """base-51.csv + batches/*.csv → {本地id: (标题, 标签串)}（utf-8-sig 兼容 BOM）"""
    mapping = {}
    csvs = [os.path.join(ROOT, 'assets-local', 'base-51.csv')]
    batches_dir = os.path.join(ROOT, 'assets-local', 'batches')
    if os.path.isdir(batches_dir):
        csvs += [os.path.join(batches_dir, f) for f in sorted(os.listdir(batches_dir))
                 if f.endswith('.csv')]
    for path in csvs:
        if not os.path.exists(path):
            continue
        with io.open(path, 'r', encoding='utf-8-sig', newline='') as fh:
            for row in csv.DictReader(fh):
                rid = (row.get('id') or '').strip()
                if rid:
                    mapping[rid] = ((row.get('title') or '').strip(),
                                    (row.get('tags') or '').strip())
    return mapping


def filename_tokens(image_url: str):
    """imageUrl → 有意义的英文 token 列表（12019_sunset_2080072.jpg → ['sunset']）"""
    name = image_url.rsplit('/', 1)[-1].rsplit('.', 1)[0]
    return [t for t in re.split(r'[_\-\s]+', name.lower()) if t and not NUMBER_TOKEN.match(t)]


def tags_from_tokens(tokens):
    out = []
    for t in tokens:
        for zh in KEYWORD_DICT.get(t, []):
            if zh not in out:
                out.append(zh)
    return out


def looks_like_code_title(title: str) -> bool:
    """内部编号标题：形如「风景-00434087」或纯数字/含长数字串"""
    if not title:
        return True
    if re.search(r'-\d{4,}', title) or re.search(r'\d{5,}', title):
        return True
    return False


def suggest(row, local_csv):
    local_id = (row.get('description') or '').strip()
    cat = ((row.get('category') or {}) or {}).get('name', '') or ''
    color = row.get('dominantColor') or ''
    tokens = filename_tokens(row.get('imageUrl') or '')
    zh_tags = tags_from_tokens(tokens)

    tags = []
    for t in ([cat] if cat else []) + zh_tags + ([color] if is_cjk_name(color) else []):
        if t and t not in tags:
            tags.append(t)

    # 标题：本地 csv 的规范标题 > 「分类·关键词」> 保持现状
    if local_id and local_id in local_csv:
        title = local_csv[local_id][0] or ''
    elif zh_tags and cat:
        title = f'{cat}·{zh_tags[0]}'
    elif zh_tags:
        title = zh_tags[0]
    else:
        title = ''
    return local_id, cat, tags, title


def main():
    parser = argparse.ArgumentParser(description='生成壁纸元数据治理初稿 CSV')
    parser.add_argument('--base', default=DEFAULT_BASE)
    parser.add_argument('--out', default=os.path.join(HERE, 'metadata_draft.csv'))
    args = parser.parse_args()

    print(f'== 拉取线上壁纸（{args.base}）==')
    rows = fetch_all_wallpapers(args.base)
    if not rows:
        print('!! 未拉到任何壁纸，检查网络/后端')
        sys.exit(1)

    print('== 读取本地 csv 标题/标签 ==')
    local_csv = load_local_csv_titles()
    print(f'  本地规范条目：{len(local_csv)}')

    out_rows, code_titles, matched_local = 0, 0, 0
    with io.open(args.out, 'w', encoding='utf-8-sig', newline='') as fh:
        writer = csv.writer(fh)
        writer.writerow(['server_id', 'local_id', 'current_title', 'suggested_title',
                         'suggested_tags', 'category', 'dominant_color', 'orientation',
                         'width', 'height', 'image_url', 'reviewed_title', 'reviewed_tags'])
        for row in rows:
            sid = row.get('id')
            title = row.get('title') or ''
            local_id, cat, tags, stitle = suggest(row, local_csv)
            if looks_like_code_title(title):
                code_titles += 1
            if local_id and local_id in local_csv:
                matched_local += 1
            writer.writerow([sid, local_id, title, stitle, ','.join(tags), cat,
                             row.get('dominantColor') or '',
                             row.get('orientation') or '', row.get('width') or 0,
                             row.get('height') or 0, row.get('imageUrl') or '', '', ''])
            out_rows += 1

    print(f'\n== 完成：共 {out_rows} 条写入 {args.out}')
    print(f'   内部编号标题（重点治理对象）：{code_titles} 条')
    print(f'   能从本地 csv 回填规范标题：{matched_local} 条')
    print('\n下一步：人工复核 reviewed_title / reviewed_tags 两列（留空=采纳初稿，填 - =跳过），')
    print('       然后运行 python tools/apply_metadata.py tools/metadata_draft.csv 生成 SQL。')


if __name__ == '__main__':
    main()
