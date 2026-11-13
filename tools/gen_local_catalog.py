# -*- coding: utf-8 -*-
"""
生成离线版的单一壁纸目录 LocalWallpapers.ets

数据来源：
  1. assets-out/wallpapers-import.csv —— 51 条真实素材（原云素材，现改为随包内置）
  2. 本文件内的 LEGACY_PERSONAL —— 12 条个人宠物照片（纯本地，无网络地址）

产出：entry/src/main/ets/common/constants/LocalWallpapers.ets

⚠️ 已移除的旧内容：原先 10 张 wf_* 是 **粉色数字占位图**（default_wallpaper_01~10.png），
   不是真实壁纸，已于 2026-09-13 一并删除。

用法：E:\\Anaconda\\python.exe tools\\gen_local_catalog.py
"""
import csv
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 清单已从 assets-out/ 迁到 assets-local/：后者是本工程离线版自己的素材目录，
# 而 assets-out/ 是云端时代管线的产物，文件常被 DevEco 索引占用而写不进去。
CSV_IN = os.path.join(ROOT, "assets-local", "base-51.csv")
BATCH_DIR = os.path.join(ROOT, "assets-local", "batches")
OUT_ETS = os.path.join(ROOT, "entry", "src", "main", "ets", "common", "constants", "LocalWallpapers.ets")

# 旧素材的分类名与后台合并后的口径对齐（只作用于 base-51 / 既有批次，不改新批次原始类目）
CATEGORY_ALIASES = {
    "风景": "自然风景",
    "自然风光": "自然风景",
}

# 已确认淘汰的重复图 → 保留图（2026-11-07 本地 3 组）。
# 生成时从目录剔除淘汰 id，并在资源查找处做别名解析，保证旧收藏 id 仍能出图。
DEDUP_ALIASES = {
    "jofy88_fall_1051300_1920_1": "jofy88_fall_1051300",
    "w1462_1c7d482e29": "w1546_07bfd74f9c",
    "w2004_160101601b": "w3474_28910b7791",
}

# 类别顺序：既有 4 类在前（保持原展示顺序），批次新增类目按名称稳定追加
BASE_CATEGORIES = ["自然风景", "城市建筑", "极简风格", "动物萌宠"]

# 个人宠物照片：纯本地资源（media 下 custom_cat_XX / custom_dog_XX），无网络地址
# 格式：(id, 标题, 分类, 上传时间, 标签, 资源名)
LEGACY_PERSONAL = [
    ("my_cat_01", "我的萌宠·01", "动物萌宠", 1700033000000, "萌宠,治愈", "custom_cat_01"),
    ("my_cat_02", "我的萌宠·02", "动物萌宠", 1700033600000, "萌宠,清新", "custom_cat_02"),
    ("my_cat_04", "我的萌宠·04", "动物萌宠", 1700034800000, "萌宠,梦幻", "custom_cat_04"),
    ("my_cat_06", "我的萌宠·06", "动物萌宠", 1700036000000, "萌宠,清新", "custom_cat_06"),
    ("my_dog_01", "萌犬·哈士奇", "动物萌宠", 1700037000000, "萌宠,风景", "custom_dog_01"),
    ("my_dog_03", "萌犬·恩特勒布赫", "动物萌宠", 1700038200000, "萌宠,清新", "custom_dog_03"),
    ("my_dog_04", "萌犬·蝴蝶犬", "动物萌宠", 1700038800000, "萌宠,梦幻", "custom_dog_04"),
    ("my_dog_05", "萌犬·马尔济斯", "动物萌宠", 1700039400000, "萌宠,治愈", "custom_dog_05"),
    ("my_dog_06", "萌犬·可卡布", "动物萌宠", 1700040000000, "萌宠,清新", "custom_dog_06"),
    ("my_dog_07", "萌犬·马尔济斯2", "动物萌宠", 1700040600000, "萌宠,梦幻", "custom_dog_07"),
    ("my_dog_08", "萌犬·边境柯利", "动物萌宠", 1700041200000, "萌宠,风景", "custom_dog_08"),
    ("my_dog_09", "萌犬·西里汉姆", "动物萌宠", 1700041800000, "萌宠,治愈", "custom_dog_09"),
]

# 只保留实际有图的分类；「极简风格」「二次元插画」随占位图一起删除（0 张会变空标签）
CATEGORIES = "['全部', '自然风景', '城市建筑', '极简风格', '动物萌宠']"

PRESET_TAGS = """[
    '星空', '科幻太空', '暗色', '治愈', '清新', '赛博朋克', '国风',
    '萌宠', '风景', '城市夜景', '简约', '插画', '梦幻', '暖色'
  ]"""


def esc(s):
    return (s or "").replace("\\", "\\\\").replace("'", "\\'")


def read_new():
    rows = []
    with open(CSV_IN, "r", encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            if r.get("id"):
                r["category"] = CATEGORY_ALIASES.get(r["category"], r["category"])
                rows.append(r)
    return rows


def read_batches():
    """读取 assets-local/batches/*.csv —— 由 tools/add_local_batch.py / 导入脚本产出"""
    rows = []
    if not os.path.isdir(BATCH_DIR):
        return rows
    for name in sorted(os.listdir(BATCH_DIR)):
        if not name.lower().endswith(".csv"):
            continue
        with open(os.path.join(BATCH_DIR, name), "r", encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                if not r.get("id"):
                    continue
                # 11.3 新批次直接使用 WorkBuddy 原始 category，不做类目重写
                if not name.lower().startswith("w113"):
                    r["category"] = CATEGORY_ALIASES.get(r["category"], r["category"])
                rows.append(r)
    return rows


def main():
    new = read_new()
    batches = read_batches()
    legacy = LEGACY_PERSONAL
    all_photo = new + batches

    # 淘汰的重复图不再进入目录（源 CSV 已移除；此处再做一次兜底剔除）
    dropped = [r["id"] for r in all_photo if r["id"] in DEDUP_ALIASES]
    if dropped:
        print("  [跳过] 已淘汰的重复图: %s" % ", ".join(dropped))
    all_photo = [r for r in all_photo if r["id"] not in DEDUP_ALIASES]

    # 分类由实际条目稳定生成：既有 4 类在前，批次新增类目按名称追加
    cats = list(BASE_CATEGORIES)
    for r in all_photo:
        if r["category"] not in cats:
            cats.append(r["category"])
    categories = "[" + ", ".join("'%s'" % esc(c) for c in ["全部"] + cats) + "]"

    alias_items = list(DEDUP_ALIASES.items())
    alias_str = "{" + ", ".join("'%s': '%s'" % (esc(a), esc(b)) for a, b in alias_items) + "}"

    out = []
    out.append("import { Wallpaper } from '../../model/Wallpaper';")
    out.append("")
    out.append("/**")
    out.append(" * LocalWallpapers —— 壁纸目录（全离线，不依赖任何网络与云服务）")
    out.append(" *")
    out.append(" * 由 tools/gen_local_catalog.py 生成，请勿手改：")
    out.append(" *   %d 条真实素材来自 assets-local/base-51.csv 与 assets-local/batches/*.csv" % len(all_photo))
    out.append(" *   %d 条个人宠物照片为纯本地资源（custom_cat_XX / custom_dog_XX）" % len(legacy))
    out.append(" *")
    out.append(" * 图片资源：resources/base/media/ 下")
    out.append(" *   素材    wp_<id>.jpg（长边 1440） / wp_<id>_thumb.jpg（长边 720）")
    out.append(" *   个人照片 custom_cat_XX / custom_dog_XX")
    out.append(" *")
    out.append(" * ⚠️ 原 10 张 wf_* 是粉色数字占位图（default_wallpaper_01~10.png），")
    out.append(" *    不是真实壁纸，已删除。")
    out.append(" */")
    out.append("export class LocalWallpapers {")
    out.append("  /** 核心分类（全部 = 不过滤；由实际条目生成，新增类目可直接浏览） */")
    out.append("  static readonly CATEGORIES: string[] = %s;" % categories)
    out.append("")
    out.append("  /** 已淘汰重复图的 id → 保留图 id（getLocalImg/getThumb 会解析） */")
    out.append("  static readonly DEDUP_ALIASES: Record<string, string> = %s;" % alias_str)
    out.append("")
    out.append("  /** 预置标签表 */")
    out.append("  static readonly PRESET_TAGS: string[] = %s;" % PRESET_TAGS)
    out.append("")
    out.append("  /** 全部壁纸（真实素材在前，个人照片在后） */")
    out.append("  static readonly ALL: Wallpaper[] = [")
    out.append("    // ==================== 真实素材（%d 张，随包内置） ====================" % len(all_photo))
    for r in all_photo:
        out.append("    new Wallpaper('%s', '%s', '%s', '%s', %s, '%s'),"
                   % (esc(r["id"]), esc(r["title"]), esc(r["category"]), esc(r["author"]),
                      (r["uploadTime"] or "0").strip(), esc(r["tags"])))
    out.append("")
    out.append("    // ==================== 个人宠物照片（%d 张） ====================" % len(legacy))
    for wid, title, cat, ts, tags, _ in legacy:
        out.append("    new Wallpaper('%s', '%s', '%s', '我', %d, '%s'),"
                   % (wid, title, cat, ts, tags))
    out.append("  ];")
    out.append("")
    out.append("  /** id → 本地原图资源名（media 目录下文件名去掉扩展名） */")
    out.append("  private static readonly LOCAL_IMG: Record<string, string> = {")
    for r in all_photo:
        wid = esc(r["id"])
        out.append("    '%s': 'wp_%s'," % (wid, wid))
    for wid, _, _, _, _, res in legacy:
        out.append("    '%s': '%s'," % (wid, res))
    out.append("  };")
    out.append("")
    out.append("  /** id → 本地缩略图资源名（只有素材有；个人照片回退到原图） */")
    out.append("  private static readonly LOCAL_THUMB: Record<string, string> = {")
    for r in all_photo:
        wid = esc(r["id"])
        out.append("    '%s': 'wp_%s_thumb'," % (wid, wid))
    out.append("  };")
    out.append("")
    out.append("  /** 解析重复图别名：淘汰 id 一律回落到保留 id */")
    out.append("  static resolveId(id: string): string {")
    out.append("    const keep: string | undefined = LocalWallpapers.DEDUP_ALIASES[id];")
    out.append("    return keep === undefined ? id : keep;")
    out.append("  }")
    out.append("")
    out.append("  /** 详情用图（列表外的场景：预览、编辑器、设为壁纸） */")
    out.append("  static getLocalImg(id: string): Resource | undefined {")
    out.append("    const resolved: string = LocalWallpapers.resolveId(id);")
    out.append("    const name: string | undefined = LocalWallpapers.LOCAL_IMG[resolved];")
    out.append("    if (name === undefined || name.length === 0) {")
    out.append("      return undefined;")
    out.append("    }")
    out.append("    return $r(`app.media.${name}`);")
    out.append("  }")
    out.append("")
    out.append("  /** 列表用缩略图（省内存：1440 的原图解码成本高） */")
    out.append("  static getThumb(id: string): Resource | undefined {")
    out.append("    const resolved: string = LocalWallpapers.resolveId(id);")
    out.append("    const name: string | undefined = LocalWallpapers.LOCAL_THUMB[resolved];")
    out.append("    if (name !== undefined && name.length > 0) {")
    out.append("      return $r(`app.media.${name}`);")
    out.append("    }")
    out.append("    return LocalWallpapers.getLocalImg(resolved);")
    out.append("  }")
    out.append("}")
    out.append("")

    with open(OUT_ETS, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))

    print("已生成: %s" % OUT_ETS)
    print("  真实素材: %d 条（原始 %d + 批次 %d）" % (len(all_photo), len(new), len(batches)))
    print("  类目: %s" % " / ".join(cats))
    print("  个人照片: %d 条" % len(legacy))
    print("  合计壁纸: %d 条" % (len(all_photo) + len(legacy)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
