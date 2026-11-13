# tools 使用说明

> 2026-10-25 建立：仓库清理后（docs-site 生成管线删除），本目录只保留仍在维护期的脚本。
> 所有脚本均为 Python 3 标准库实现，无第三方依赖；在服务器上执行时注意绕过本机代理。

## 元数据治理（1.4.0 第三批，2026-10-25）

线上壁纸 tags 全空、标题多为内部编号，是「搜索永远 0 结果」的根因（CURRENT-STATE P1）。
搜索基建（后端 `?keyword=` + App 服务端搜索）已就位，缺的只是内容元数据。治理流程：

```bash
# ① 生成初稿：拉取全部线上壁纸，按 本地csv标题/文件名词典/分类主色 推断标题+标签
python tools/gen_metadata_draft.py
#    → 产出 tools/metadata_draft.csv，重点看「内部编号标题」统计数

# ② 人工复核（表格软件打开），只填两列：
#    reviewed_title / reviewed_tags：留空=采纳初稿；填「-」=该行跳过不改

# ③ 生成 SQL 并在服务器执行（宝塔数据库导入或 mysql source）
python tools/apply_metadata.py tools/metadata_draft.csv
#    → 产出 tools/metadata_updates.sql（幂等，可重复执行）

# ④ 验证：App 图库任意合辑搜「日落」「猫」应出结果；/api/v1/wallpapers?keyword=猫 直接 curl 验证
```

词表在 `gen_metadata_draft.py` 的 `KEYWORD_DICT` 里，随治理推进持续补充即可。

**2026-10-25 首轮已完成**（AI 代人工复核）：
- 标签全部导入（分类+主色，1605 行）；标题仅改写 27 条「每日精选 · 第 0 期」；
- 导入时发现批量替换会覆盖种子图的 102 条主题标签，已用 `metadata_seed_fix.sql`
  （生成器 `_seed_tag_fix.py`，csv 主题标签 ∪ 分类/主色）回填修复；
- 实测：自然风景 528 / 日落 4 / 猫 2 / 每日精选 27 条命中。
- **下一轮治理对象**：402 条内部编号标题（如「什锦-0d6d20f5」）——文件名是 UUID 无从推断，
  需人工看图打标或接视觉模型批量打标（建议小批量人工校准后再放量）。
- 同批还配了版本记录：`app_version_config.sql`（harmony/1.2.0/1002000，1.3.0 过审后 UPDATE）。

## 保留的其它脚本

| 脚本 | 用途 |
|---|---|
| `contrast_audit.py` / `contrast_report.py` | 1.1.0 配色对比度标准审计（现行标准，改配色必须跑） |
| `fix_contrast_*.py` / `fix_theme_comments.py` | 2026-09-29 对比度整改的历史修数脚本（留档，一般不再运行） |
| `build_review_doc.py` | 生成审核整改说明的 html/pdf（下次提审还要用） |
| `gen_local_catalog.py` / `prepare_local_assets.py` / `add_local_batch.py` | 本地 51 张兜底目录的生成管线（改动 resources 内置图时用） |
| `sync_local_categories.py` | 本地分类与后台分类同步核对 |

## 已删除（2026-10-25 清理）

- `build_docs_site.py` + `docs-site/`：文档站生成管线，源文档已删/过时；
- `prepare_cloud_assets.py`：AGC 云存储时代的上传打包（路线已弃）。
