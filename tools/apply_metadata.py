# -*- coding: utf-8 -*-
"""
apply_metadata.py —— 壁纸元数据治理·SQL 生成器（2026-10-25 第三批）

读取 gen_metadata_draft.py 产出并经人工复核的 CSV（reviewed_title / reviewed_tags
两列：留空=采纳初稿，填「-」=跳过该行），生成可直接执行的 metadata_updates.sql：

  1. 标题更新：UPDATE wallpapers SET title=... WHERE id=...（仅标题真正变化的行）；
  2. 标签重建：先 DELETE 该壁纸在隐式中间表 _TagToWallpaper 的旧关联，
     再 INSERT IGNORE INTO tags + 关联（幂等，可重复执行）。

表名/列名与 prisma/migrations/0_init 一致：
  tags(id, name UNIQUE, created_at)；_TagToWallpaper(A=tag_id, B=wallpaper_id)。

用法：
  python tools/apply_metadata.py tools/metadata_draft.csv [--out tools/metadata_updates.sql]
  然后在服务器 MySQL 执行（宝塔 → 数据库 → 导入，或 mysql -u... -e "source ...").
  执行后建议重启后端容器（合辑物化列表 60s TTL 内自会刷新，无需重启也可）。
"""
import argparse
import csv
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def sql_str(value: str) -> str:
    """SQL 字符串转义（反斜杠 + 单引号）"""
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"


def main():
    parser = argparse.ArgumentParser(description='把复核后的元数据 CSV 转成 SQL')
    parser.add_argument('csv_path')
    parser.add_argument('--out', default=os.path.join(HERE, 'metadata_updates.sql'))
    args = parser.parse_args()

    title_stmts, tag_stmts, skipped = [], [], 0
    total = 0
    with io.open(args.csv_path, 'r', encoding='utf-8-sig', newline='') as fh:
        for row in csv.DictReader(fh):
            total += 1
            sid = (row.get('server_id') or '').strip()
            if not sid or not sid.isdigit():
                skipped += 1
                continue
            cur_title = (row.get('current_title') or '').strip()
            rev_title = (row.get('reviewed_title') or '').strip()
            sug_title = (row.get('suggested_title') or '').strip()
            rev_tags = (row.get('reviewed_tags') or '').strip()
            sug_tags = (row.get('suggested_tags') or '').strip()

            # 「-」= 人工标记跳过该行（保持线上现状）
            if rev_title == '-' and rev_tags == '-':
                skipped += 1
                continue

            new_title = rev_title if rev_title and rev_title != '-' else sug_title
            if new_title and new_title != cur_title:
                title_stmts.append(
                    f'UPDATE wallpapers SET title = {sql_str(new_title)} WHERE id = {sid};')

            tag_str = rev_tags if rev_tags and rev_tags != '-' else sug_tags
            tags = [t.strip() for t in tag_str.replace('，', ',').split(',') if t.strip()]
            if tags:
                tag_stmts.append(f'DELETE FROM `_TagToWallpaper` WHERE `B` = {sid};')
                for t in tags:
                    tag_stmts.append(
                        f'INSERT IGNORE INTO `tags` (`name`, `created_at`) '
                        f'VALUES ({sql_str(t)}, NOW());')
                    tag_stmts.append(
                        f'INSERT IGNORE INTO `_TagToWallpaper` (`A`, `B`) '
                        f'SELECT `id`, {sid} FROM `tags` WHERE `name` = {sql_str(t)};')

    with io.open(args.out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('-- 元数据治理导入（由 apply_metadata.py 生成，人工复核后的结果）\n')
        fh.write('-- 幂等：标题 UPDATE 不重复生效；标签 DELETE+INSERT IGNORE 可重复执行。\n')
        fh.write(f'-- 共 {total} 行，跳过 {skipped} 行，标题更新 {len(title_stmts)} 条，'
                 f'标签语句 {len(tag_stmts)} 条。\n\n')
        fh.write('-- ===== 1. 标题 =====\n')
        fh.write('\n'.join(title_stmts) + ('\n' if title_stmts else ''))
        fh.write('\n-- ===== 2. 标签（先清旧关联再建新）=====\n')
        fh.write('\n'.join(tag_stmts) + ('\n' if tag_stmts else ''))

    print(f'== 完成：{args.out}')
    print(f'   标题 UPDATE {len(title_stmts)} 条 / 标签语句 {len(tag_stmts)} 条 / 跳过 {skipped} 行')
    print('   请人工过目 SQL 后在服务器 MySQL 执行；执行后可搜「日落/猫」验证 App 全库搜索。')


if __name__ == '__main__':
    main()
