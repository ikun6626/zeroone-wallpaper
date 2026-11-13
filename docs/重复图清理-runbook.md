# 重复图清理 Runbook（296 张 · 分 6 批）

> 生成日期：2026-11-07　｜　对应方案：`产品改进方案-五项.md` §5A.7
> 数据来源：`docs/去重表-2026-11-05.csv`（289 组、296 张、唯一 1323 张）
> 批次清单：[重复图清理-批次清单.csv](file:///e:/zeroone/docs/重复图清理-批次清单.csv)
>
> **本文件只写步骤，不执行删除。** 所有 SQL 均需在维护窗口人工执行；每条命令前先确认批次号。

---

## 0. 硬前提

1. **先软删 30 天，再物理删除**；软删期间用户可恢复、可回滚，物理删除后只能靠备份。
2. **禁止 `DELETE FROM wallpapers` 直接删**。库里有两个 `ON DELETE CASCADE` 外键（合辑、收藏），直接删会静默清掉引用行。
3. 每批一个事务；事务外先备份该批 `keep`/`dup` 行与关联行。
4. 物理删除只在软删满 30 天、且该批校验全部通过后执行。
5. 任何一步失败：先回滚本批事务，再按 §7 恢复，不要带着半批继续。

---

## 1. 引用关系实地核查（基于 schema.prisma 与后端代码）

| # | 引用点 | 关系/外键 | 删除后的影响 | 处理动作 | 依据 |
|---|---|---|---|---|---|
| 1 | `wallpapers` 自身 | — | 软删只改 `deleted_at`/`status`；`App` 列表按 `deletedAt:null + PUBLISHED` 过滤，删除后自然消失 | 软删：`status=OFFLINE`，`deleted_at=NOW()`，新增 `archived_at` 与 `dedup_batch` | `prisma/schema.prisma` L71-108；`app-api.service.ts` L94-97 |
| 2 | `album_wallpapers` | `wallpaperId` → `wallpapers.id`，**onDelete: Cascade** | 硬删会永久删掉该合辑内的人工排序项；软删不删行，但合辑读模型只取 PUBLISHED 行，页面上自动消失（可随恢复回来） | 软删前把 dup 的人工项迁到 keep（同合辑已有 keep 则跳过），插入行记入 `merge_log`；**不删原行** | `schema.prisma` L249-259；`albums.service.ts` L93-108、L224-231 |
| 3 | `favorites` | `wallpaperId` → `wallpapers.id`，**onDelete: Cascade** | 硬删会静默清掉用户收藏；软删后收藏仍在表里，但云端收藏列表查不到该图 | 默认**读时映射**（dup→keep）；需要长期保留时按 `merge_log` 插入 keep 收藏并记录 `(user_id, keep_id, copied_at)` | `schema.prisma` L285-295；`favorites.service.ts` L48-67 |
| 4 | `daily_featured` | `wallpaper_id` **无外键**、可空 | 留下悬空 id：`homeComposition` 查不到该图 → 每日精选大卡 `wallpaper=null`，点击无反应 | 软删前 `UPDATE daily_featured SET wallpaper_id=keep WHERE wallpaper_id=dup`，原值写 `merge_log` | `schema.prisma` L198-212；`albums.service.ts` L445-463 |
| 5 | `banners` | `linkValue` 字符串 **无外键**（`linkType=WALLPAPER` 时存 id） | 悬空：Banner 点击跳转到已删图，App 打开 404/空详情 | 软删前 `UPDATE banners SET link_value=keep WHERE link_type='WALLPAPER' AND link_value=dup`，原值写 `merge_log` | `schema.prisma` L118-132；`banners.service.ts` L21 |
| 6 | `albums.rule` | JSON 字符串，**不含图片 id**；含 `categoryIn / dominantColorIn / orientation / tagAny / minBrightness / maxBrightness / **minDownloads** / source` | 不产生悬空；但计数合并后 `minDownloads` 门槛可能让某图「新进」自动合辑 → 合辑成员变化 | 合并计数后跑 §3.3 的成员差异查询，逐条确认；差异写 `merge_log.note` | `albums.service.ts` L70、L215-243 |
| 7 | `categories` 计数 | `Category._count.wallpapers` 只按 `status='PUBLISHED'`，**没有过滤 `deletedAt`** | 若软删只写 `deleted_at` 不改 `status`，图库分类数量会偏大 | 软删必须同时 `status=OFFLINE`（现有 `remove()` 已这么做） | `app-api.service.ts` L85；`wallpapers.service.ts` L200-207 |
| 8 | `stats` 看板 | 全部查询 `deletedAt: null`，累计求和 `viewCount/downloadCount/likeCount` | 删除后总量下降；若不合并计数，历史用量凭空消失 | 计数合并进 keep + 软删 dup 同一事务 → 总量守恒；`merge_log` 记录每笔来源 | `stats.service.ts` L20-72 |
| 9 | 标签关联（隐式 `_WallpaperToTag`） | Prisma 多对多，随壁纸硬删级联 | keep 的标签不受影响；dup 的标签随行消失 | 软删不动；物理删前确认 keep 已有同名标签（同内容通常同标签），缺则补 | `schema.prisma` L54-61、L87 |
| 10 | 下载/浏览历史 | **不存在事件表**；只有 `wallpapers.view_count/download_count` 累计列 | 没有「下载记录」可迁移；删除只影响这两列 | 计数合并（见 §3.1）；不新建历史表 | `app-api.service.ts` L129-147 |
| 11 | App 本地收藏快照 | `PreferenceUtil.getFavoriteItems()` 按 id 存整条壁纸 | 用户本地可能仍留着 dup id：软删后还能靠快照显示；物理删文件后缩略图 404 | 上线 `dedup_map`（dup→keep）；App 启动时把本地收藏 id 迁移到 keep（P1 客户端改动） | `FavoriteSync.ets` L75-90；`MinePage.ets` L137-146 |
| 12 | 存储文件 | `StorageService.delete(key)` 同时支持 local / OSS（`STORAGE_DRIVER`） | 只删 DB 会留下孤儿文件；先删文件会让线上立即 404 | 物理删阶段先删 DB 再删文件，失败进重试队列；孤儿清理单独跑 | `storage.service.ts` L22-54、L219-266；`oss-storage.driver.ts` L36-38 |

**结论（是否影响其他图片/合辑/收藏）**

- **不影响其他图片**：`wallpapers` 无自引用；`dedup_keep_id` 指向 keep，删除只针对 `dup` 行，keep 行不动。
- **会影响合辑**：硬删会级联删除人工排序项；软删会让合辑成员数下降（内容不变，因为 keep 同图仍在）。必须在软删前迁移人工项。
- **会影响收藏**：硬删会静默删除 `favorites` 行；软删不会删数据但列表看不到。必须做读时映射或迁移。
- **不影响标签定义**：`tags` 表本身不动，只删关联。
- **会有悬空引用**：`daily_featured.wallpaper_id`、`banners.link_value` 都没有外键，**必须手工改写**，否则大卡/Banner 点击失效。

---

## 2. 前置备份（每批执行前）

```bash
# 2.1 全库逻辑备份（含存储过程/触发器；单事务，不锁写）
mysqldump -h <host> -u <user> -p --single-transaction --routines --triggers \
  --default-character-set=utf8mb4 <db> > backup_before_dedup_$(date +%Y%m%d_%H%M).sql

# 2.2 仅本批相关行（便于快速回滚，不必整库恢复）
mysql -h <host> -u <user> -p <db> -e "
SELECT * FROM wallpapers WHERE id IN (<batch_keep_ids>, <batch_dup_ids>) INTO OUTFILE '/tmp/B01_wallpapers.tsv';
SELECT * FROM album_wallpapers WHERE wallpaper_id IN (<batch_dup_ids>) INTO OUTFILE '/tmp/B01_album_items.tsv';
SELECT * FROM favorites WHERE wallpaper_id IN (<batch_dup_ids>) INTO OUTFILE '/tmp/B01_favorites.tsv';
SELECT * FROM daily_featured WHERE wallpaper_id IN (<batch_dup_ids>) INTO OUTFILE '/tmp/B01_daily.tsv';
SELECT * FROM banners WHERE link_type='WALLPAPER' AND CAST(link_value AS UNSIGNED) IN (<batch_dup_ids>) INTO OUTFILE '/tmp/B01_banners.tsv';
"

# 2.3 文件清单（物理删阶段用；先记录 key、大小、ETag/更新时间）
# 从 image_url / thumb_url 提取 key，落到 docs/dedup-files-B01.csv
```

- 备份校验：`wc -l` 行数必须等于本批 dup 数；`wallpapers` 文件含 keep 与 dup。
- 备份文件保存 90 天（软删 30 天 + 缓冲 60 天），不要放 Web 可访问目录。

---

## 3. 数据归并与口径

### 3.1 计数合并（默认：累加 + 留痕）

同一内容的不同分辨率版本，历史浏览/保存是**内容级**用量；删除后若不合并，看板总量会凭空减少。

```sql
START TRANSACTION;
-- 3.1.1 先把 dup 的计数加到 keep（同组多张时逐张加）
UPDATE wallpapers k
JOIN wallpapers d ON d.id = <dup_id>
SET k.view_count = k.view_count + d.view_count,
    k.download_count = k.download_count + d.download_count,
    k.like_count = k.like_count + d.like_count
WHERE k.id = <keep_id>;

-- 3.1.2 留痕（新建表，见 00_schema.sql）
INSERT INTO merge_log (keep_id, dup_id, batch_no, merged_view, merged_download, merged_like,
                       keep_view_before, keep_view_after, note, created_at)
VALUES (<keep_id>, <dup_id>, 'B01', <dup_view>, <dup_download>, <dup_like>,
        <keep_view_before>, <keep_view_after>, 'count merged', NOW());
```

**口径污染说明（必须写进看板注释）**

- `download/view` 比例变成「多版本历史混合」，不再等于单图当前保存率；推荐打分用 `Q_save` 时，需按 `merge_log` 还原或用埋点表重新计算。
- `albums.rule.minDownloads` 可能因此跨过门槛 → 自动合辑成员变化（见 §3.3）。
- 种子数据若已灌入，合并会把两个种子值相加；种子批次必须**先清理再清理图**，或按 `seed_batch` 单独处理，不参与累加。

### 3.2 收藏与合辑的人工项

```sql
-- 收藏：插入 keep（复合主键天然幂等），并把插入对记录到 merge_log
INSERT INTO favorites (user_id, wallpaper_id, created_at)
SELECT f.user_id, <keep_id>, f.created_at
FROM favorites f
WHERE f.wallpaper_id = <dup_id>
ON DUPLICATE KEY UPDATE created_at = LEAST(favorites.created_at, VALUES(created_at));
-- 记录：INSERT INTO merge_log (..., note) VALUES (..., 'favorite copied');

-- 合辑人工项：同合辑没有 keep 才插，sort 沿用 dup 的 sort
INSERT INTO album_wallpapers (album_id, wallpaper_id, sort)
SELECT aw.album_id, <keep_id>, aw.sort
FROM album_wallpapers aw
WHERE aw.wallpaper_id = <dup_id>
  AND NOT EXISTS (SELECT 1 FROM album_wallpapers x
                  WHERE x.album_id = aw.album_id AND x.wallpaper_id = <keep_id>);
-- 原 dup 行保留，硬删时随外键级联消失
```

### 3.3 规则合辑差异核对（每批前后各跑一次）

```sql
-- 对每个 rule 合辑，比较「成员集合（按 keep_id 归一）」是否变化
-- 先在应用层调用 /admin/albums 导出每辑 wallpaperId 列表，diff 两份 JSON
-- 预期：只允许 dup→keep 的归一，不允许新增/丢失内容
```

---

## 4. 软删阶段（第 0~30 天）

### 4.1 单批事务模板（B01 示例，替换 id 列表）

```sql
START TRANSACTION;

-- ① 标记归档（新增列 archived_at / dedup_batch；status 必须改 OFFLINE，否则分类计数偏大）
UPDATE wallpapers
SET status = 'OFFLINE',
    deleted_at = NOW(),
    archived_at = NOW(),
    dedup_batch = 'B01'
WHERE id IN (<B01_dup_ids>) AND deleted_at IS NULL;

-- ② 计数合并（逐组执行 3.1.1，或由脚本生成）
-- ③ 收藏/合辑迁移（3.2）
-- ④ 每日精选 / Banner 改写（§1 #4 #5）
-- ⑤ 写 merge_log

COMMIT;
```

结构变更（只执行一次）：

```sql
ALTER TABLE wallpapers ADD COLUMN archived_at DATETIME NULL;
ALTER TABLE wallpapers ADD COLUMN dedup_batch VARCHAR(16) NOT NULL DEFAULT '';
ALTER TABLE wallpapers ADD COLUMN dedup_keep_id INT NULL;
ALTER TABLE wallpapers ADD COLUMN phash BIGINT NULL;
CREATE INDEX idx_wallpapers_dedup_keep ON wallpapers (dedup_keep_id);
CREATE INDEX idx_wallpapers_archived ON wallpapers (archived_at);
CREATE TABLE merge_log (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  keep_id INT NOT NULL,
  dup_id INT NOT NULL,
  batch_no VARCHAR(16) NOT NULL,
  merged_view INT NOT NULL DEFAULT 0,
  merged_download INT NOT NULL DEFAULT 0,
  merged_like INT NOT NULL DEFAULT 0,
  keep_view_before INT NOT NULL DEFAULT 0,
  keep_view_after INT NOT NULL DEFAULT 0,
  note VARCHAR(200) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_dup (dup_id),
  KEY idx_batch (batch_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 4.2 每批执行前后校验（必须全绿才进下一批）

| 校验项 | SQL / 方法 | 期望 |
|---|---|---|
| 本批行数 | `SELECT COUNT(*) FROM wallpapers WHERE dedup_batch='B01' AND archived_at IS NOT NULL` | = 批次清单行数（50/46） |
| 可见总数 | `SELECT COUNT(*) FROM wallpapers WHERE deletedAt IS NULL AND status='PUBLISHED'` | 批前 − 批行数 |
| 唯一内容数 | `SELECT COUNT(*) FROM wallpapers WHERE deleted_at IS NULL AND status='PUBLISHED' AND (dedup_keep_id IS NULL OR dedup_keep_id=id)` | **不变**（1323） |
| 首页候选 | `SELECT COUNT(*) FROM wallpapers WHERE deletedAt IS NULL AND status='PUBLISHED' AND dedup_keep_id=id AND width>=1080 AND height>=1080` | ≥ 40（16 精选 + 24 推荐缓冲） |
| 固定位无 dup | 查 `home_slots`（§11 新建）里是否含本批 dup id | 0 条 |
| 合辑覆盖 | 每辑导出 keep_id 集合 diff | 内容集合不变 |
| 收藏 | `SELECT COUNT(*) FROM favorites WHERE wallpaper_id IN (<dup_ids>)`（迁移后） | 0 或已映射 |
| 每日精选 | `SELECT COUNT(*) FROM daily_featured WHERE wallpaper_id IN (<dup_ids>)` | 0 |
| Banner | `SELECT COUNT(*) FROM banners WHERE link_type='WALLPAPER' AND CAST(link_value AS UNSIGNED) IN (<dup_ids>)` | 0 |
| 计数守恒 | 全库 `SUM(view_count)` 批前/批后 | 不变（±0） |

> 合辑缓存 15 秒（`MATERIAL_TTL_MS=15000`）；校验前等 15 秒或调用 `invalidate()`，否则读到旧物化数据。

---

## 5. 物理删除阶段（第 31 天起）

### 5.1 顺序

1. 确认批次 `archived_at <= NOW() - INTERVAL 30 DAY`，且 §4.2 全绿。
2. **先删 DB 行**（避免 UI 还指向已删文件），事务内按批删。
3. **再删文件**（幂等重试），最后刷 CDN。
4. 记录 `purge_log`（可复用 `merge_log` 的 note，或单独表）。

```sql
START TRANSACTION;
DELETE FROM wallpapers
WHERE dedup_batch='B01'
  AND archived_at <= NOW() - INTERVAL 30 DAY
  AND deleted_at IS NOT NULL;
COMMIT;
-- 预期影响行数 = 本批 dup 数；同时级联删除 album_wallpapers / favorites 中残留的 dup 行
```

### 5.2 文件删除（幂等）

- 驱动：`StorageService.delete(key)`；`STORAGE_DRIVER=local` 走本地 `unlink`，`=oss` 走 `client.delete(key)`。
- `key` 提取：`storage.service.ts#L219-L266` 的 `localKeyFromUrl` 只适用于本地；OSS 用 `image_url` 去掉 CDN/域名后的路径。
- 幂等：404 / NoSuchKey 视为成功；其它错误重试 3 次（指数退避 1/5/30 秒），仍失败进 `purge_retry` 清单，下一轮再跑。
- 两张图都要删：`image_url` 与 `thumb_url`（若不同）。
- CDN：ali-oss 删除源站对象后，CDN 边缘可能仍缓存；需在 CDN 控制台刷新对应 URL，或等 TTL。**没有自动 purge 凭据，不写进脚本**。
- 孤儿文件：单独月度任务，扫描 `wallpapers.image_url/thumb_url`、`banners.image_url`、`albums.cover_url`、`daily_featured.image_url` 的并集，再比对存储清单；不要只比壁纸表，否则会误删 Banner/合辑封面。

---

## 6. 失败与回滚

### 6.1 单批回滚（软删阶段，事务已提交后）

```sql
START TRANSACTION;
-- ① 恢复壁纸可见性（只回滚本批）
UPDATE wallpapers
SET status='PUBLISHED', deleted_at=NULL, archived_at=NULL, dedup_batch=''
WHERE dedup_batch='B01';

-- ② 回滚计数：从 merge_log 逐条减回
UPDATE wallpapers k JOIN merge_log m ON m.keep_id=k.id
SET k.view_count = k.view_count - m.merged_view,
    k.download_count = k.download_count - m.merged_download,
    k.like_count = k.like_count - m.merged_like
WHERE m.batch_no='B01';

-- ③ 回滚收藏/合辑插入：按 merge_log 记录精确删除（不要按 keep_id 全删）
-- ④ 回滚 daily_featured / banners：merge_log 存了原值
DELETE FROM merge_log WHERE batch_no='B01';
COMMIT;
```

### 6.2 整库回滚

```bash
mysql -h <host> -u <user> -p <db> < backup_before_dedup_YYYYMMDD_HHMM.sql
```

### 6.3 文件已删怎么办

- 文件删除在物理阶段，此时备份仍在（90 天）；
- 从备份/对象存储版本恢复原文件，或从 `dup_url` 重新抓取；
- 若原文件不可恢复，无法回滚到「可见」——所以**物理删除必须等 30 天且确认**。

---

## 7. 批次清单（实际 6 批）

| 批次 | 张数 | 涉及 keep 数 | dup_id 范围 | 说明 |
|---|---|---|---|---|
| B01 | 50 | 48 | 53~348 | 含 2 个 3 张组 |
| B02 | 50 | 50 | 102~334 | 全为成对 |
| B03 | 50 | 50 | 105~333 | 全为成对 |
| B04 | 50 | 48 | 107~387 | 含 2 个 3 张组 |
| B05 | 50 | 50 | 104~335 | 全为成对 |
| B06 | 46 | 43 | 113~1594 | 收尾，含最大组 |

- 合计 **296 张 / 289 组 / 6 批**；每批独立事务、独立回滚。
- 同一 `keep_id` 的所有 dup 保证落在同一批（按 keep 分组切批）。
- 逐行清单（batch_no / seq / keep_id / dup_id / distance / 状态）见 [重复图清理-批次清单.csv](file:///e:/zeroone/docs/重复图清理-批次清单.csv)。
- 建议节奏：每天 1 批，6 天完成软删；第 31 天起每天 1 批物理删。

---

## 8. 首页不空位兜底

1. **查询层**：首页/推荐流只取 `dedup_keep_id = id`，天然排除 dup。
2. **固定 16 位**：`home_slots` 里若指向 dup，软删前改成 keep；App 渲染时若某固定位取不到图，从「质量分前 30% 池」顺位补一张，**不允许留空占位**。
3. **推荐流**：候选池按 `keep_id` 去重后必须 ≥ 40 张（16 精选 + 24 缓冲）；不足 40 时降级为「全库 keep 图按质量分」，不启用探索位。
4. **上线前演练**：在预发库跑完 6 批软删，截图首页首屏 + 推荐流前 3 屏，确认 16 格全满、无重复、无 404。

---

## 9. 上传口防复发（P1，与 §5A.7 同步上线）

1. 上传/入库时算 64bit pHash（与离线脚本同参数）。
2. 查 `dedup_keep_id=id` 的候选行，汉明 ≤6 视为疑似重复。
3. 命中则**拦截**，返回 `409`：
   ```json
   { "code": "DUPLICATE_IMAGE", "existingId": 123, "distance": 3,
     "existingUrl": "https://...", "keepWidth": 1920, "keepHeight": 1280 }
   ```
4. 后台可「强制入库」：写 `dup_of=existingId`、`dedup_keep_id=NULL`、`force_note`，并进入去重管理页待处理；强制的图不参与首页候选。
5. 新图入库即写 `phash`；历史图在软删批次里顺带回填（离线脚本已产出全库哈希缓存）。

---

## 10. 与后台 §11 的联动

- **去重管理页**：读 `merge_log` + `dedup_keep_id`，缩略图并排、默认保留最高分辨率、支持人工改判（写 `dedup_keep_id`）、勾选批量软删/恢复、导出本批 CSV。
- **素材批次页**：展示本 runbook 的 6 批状态（待执行/软删中/可物理删/已物理删）。
- **种子数据页**：清理图之前先确认 `seed_batch` 状态，避免种子计数被合并进 keep（§3.1）。
- **看板**：新增「合并来源」入口，按 `merge_log` 解释总量守恒；`download/view` 比例注明混合口径。
