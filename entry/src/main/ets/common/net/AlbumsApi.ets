import { Wallpaper } from '../../model/Wallpaper';
import { DedupKeeps } from '../constants/DedupKeeps';
import { ApiConfig } from './ApiConfig';
import { HttpClient, ApiResponse } from './HttpClient';

/**
 * AlbumsApi —— 合辑接口封装（后台可配置，改合辑不需要发版）
 *
 * 后端：
 *   GET /api/v1/albums                 合辑列表（封面 + 张数 + 是否上首页）
 *   GET /api/v1/albums/:slug           合辑内容（分页）
 *   GET /api/v1/home/composition       首页编排（每日精选 + 首页合辑位）
 *
 * 容错：任何一步失败都返回空数组/null，页面降级到内置目录，不抛错、不白屏。
 */

/** 后端合辑列表项 */
interface ApiAlbum {
  slug: string;
  name: string;
  subtitle: string;
  coverUrl: string;
  count: number;
  showOnHome: boolean;
  homeSlot: number;
}

/** 分类引用（ArkTS 不允许内联对象字面量当类型，必须具名） */
interface ApiCategoryRef {
  id: number;
  name: string;
}

/** 标签引用（合辑详情里的 tags，需映射回 Wallpaper.tags） */
interface ApiTagRef {
  id: number;
  name: string;
}

/**
 * 颜色名是否可用：只接受 1~4 个基本区/扩展A汉字。
 *
 * 线上曾出现 `dominant_color` 编码损坏（JSON 里是 U+FFFD 替换字符，如 "�Ȼ�"），
 * 后端 /colors 把它当成独立颜色桶返回 count=1，App 会把它渲染成一个乱码 chip。
 * 这类值一律丢弃 —— 改 App 修不了那一条坏数据，但可以不让它出现在界面上。
 */
function isValidColorName(name: string): boolean {
  const n: number = name.length;
  if (n === 0 || n > 4) {
    return false;
  }
  for (let i = 0; i < n; i++) {
    const code: number = name.charCodeAt(i);
    const cjk: boolean = (code >= 0x4E00 && code <= 0x9FFF) || (code >= 0x3400 && code <= 0x4DBF);
    if (!cjk) {
      return false;
    }
  }
  return true;
}

/** 后端合辑详情里的单张壁纸（字段比 /wallpapers 精简，daily 合辑甚至没有分类/尺寸） */
interface ApiAlbumItem {
  id: number;
  title: string;
  imageUrl: string;
  thumbUrl: string | null;
  dominantColor?: string | null;
  width?: number;
  height?: number;
  orientation?: string | null;
  /** 浏览数（后台统计；旧数据可能缺失） */
  viewCount?: number;
  /** 下载/保存数（后台统计；旧数据可能缺失） */
  downloadCount?: number;
  category?: ApiCategoryRef | null;
  tags?: ApiTagRef[] | null;
  publishedAt?: string | null;
  /** 对应内置壁纸时后端会写入的本地目录 id（收藏 id 以它为准，与 /wallpapers 一致） */
  description?: string | null;
  /** 每日精选特有：期号、日期、副标题 */
  issueNo?: number;
  date?: string;
  subtitle?: string;
}

interface ApiAlbumDetail {
  slug: string;
  name: string;
  subtitle: string;
  total: number;
  page: number;
  pageSize: number;
  hasMore: boolean;
  list: ApiAlbumItem[];
}

/** 首页编排里的每日精选项：比合辑项多一个"关联壁纸" */
interface ApiDailyItem {
  issueNo?: number;
  date?: string;
  title?: string;
  subtitle?: string;
  imageUrl: string;
  /** 后台填了"关联壁纸 ID"才有 */
  wallpaper?: ApiAlbumItem | null;
}

/**
 * 每日精选（首页大卡用）
 *
 * ArkTS 不允许用对象字面量当类型声明（arkts-no-obj-literals-as-types），
 * 所以这里用 class 而不是 interface，构造后再逐字段赋值。
 */
export class ApiDailyCard {
  issueNo: number = 0;
  title: string = '';
  subtitle: string = '';
  imageUrl: string = '';
  date: string = '';
  /** 关联的壁纸（后台在「今日精选管理」里填了"关联壁纸 ID"才有）：有它才能点大卡进全屏预览/保存 */
  wallpaper: Wallpaper | null = null;
}

/** 首页编排结果（class：ArkTS 不允许对象字面量做类型声明） */
export class ApiHomeComposition {
  daily: ApiDailyCard | null = null;
  albums: AlbumBrief[] = [];
}

/** App 内部使用的合辑摘要 */
export class AlbumBrief {
  slug: string = '';
  name: string = '';
  subtitle: string = '';
  coverUrl: string = '';
  count: number = 0;
  showOnHome: boolean = false;
  homeSlot: number = 0;
}

/** 主色筛选项（App 的颜色 chip 用） */
export class ColorBrief {
  color: string = '';
  count: number = 0;
}

/** 云端实时统计（「我的」页统计卡用） */
export class AppStats {
  wallpapers: number = 0;
  albums: number = 0;
}

/** 每日精选往期卡（首页横向日期列表用） */
export class DailyHistoryItem {
  issueNo: number = 0;
  /** 后端原始日期（ISO） */
  date: string = '';
  imageUrl: string = '';
  wallpaper: Wallpaper = new Wallpaper();
}

/** 合辑分页结果 */
export class AlbumPage {
  slug: string = '';
  name: string = '';
  subtitle: string = '';
  total: number = 0;
  hasMore: boolean = false;
  items: Wallpaper[] = [];
}

/**
 * 首页分区（合辑摘要 + 前 N 张壁纸占位）
 *
 * 用于 HomePage 多分区横滚：每个合辑一个分区，
 * items 异步填充（loaded=true 表示已拉到壁纸列表）。
 */
export class AlbumSection {
  slug: string = '';
  name: string = '';
  subtitle: string = '';
  coverUrl: string = '';
  count: number = 0;
  items: Wallpaper[] = [];
  loaded: boolean = false;
}

export class AlbumsApi {
  /** 合辑列表（失败返回空数组） */
  static async fetchAlbums(): Promise<AlbumBrief[]> {
    const resp: ApiResponse<ApiAlbum[]> = await HttpClient.get<ApiAlbum[]>(ApiConfig.PATH.ALBUMS);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    const out: AlbumBrief[] = [];
    const list: ApiAlbum[] = resp.data;
    for (let i = 0; i < list.length; i++) {
      const a: ApiAlbum = list[i];
      if (a === null || a === undefined || typeof a.slug !== 'string' || a.slug.length === 0) {
        continue;
      }
      const b = new AlbumBrief();
      b.slug = a.slug;
      b.name = typeof a.name === 'string' ? a.name : a.slug;
      b.subtitle = typeof a.subtitle === 'string' ? a.subtitle : '';
      b.coverUrl = typeof a.coverUrl === 'string' ? a.coverUrl : '';
      b.count = typeof a.count === 'number' ? a.count : 0;
      b.showOnHome = a.showOnHome === true;
      b.homeSlot = typeof a.homeSlot === 'number' ? a.homeSlot : 0;
      out.push(b);
    }
    return out;
  }

  /** 首页编排（失败返回 null，调用方降级） */
  static async fetchHomeComposition(): Promise<ApiHomeComposition | null> {
    interface RawHome {
      dailyFeatured: ApiDailyItem | null;
      albums: ApiAlbum[];
    }
    const resp: ApiResponse<RawHome> = await HttpClient.get<RawHome>(ApiConfig.PATH.HOME_COMPOSITION);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return null;
    }
    const raw: RawHome = resp.data;
    const out = new ApiHomeComposition();
    const d: ApiDailyItem | null = raw.dailyFeatured;
    if (d !== null && d !== undefined && typeof d.imageUrl === 'string' && d.imageUrl.length > 0) {
      const card = new ApiDailyCard();
      card.issueNo = typeof d.issueNo === 'number' ? d.issueNo : 0;
      card.title = (typeof d.title === 'string' && d.title.length > 0) ? d.title : '今日精选';
      card.subtitle = typeof d.subtitle === 'string' ? d.subtitle : '';
      card.imageUrl = d.imageUrl;
      card.date = typeof d.date === 'string' ? d.date : '';
      // 后台若关联了壁纸，这里一并带上：App 端大卡就能点进全屏预览/保存
      const linked = AlbumsApi.toLinkedWallpaper(d.wallpaper);
      card.wallpaper = linked;
      out.daily = card;
    }
    const list: ApiAlbum[] = raw.albums ?? [];
    for (let i = 0; i < list.length; i++) {
      const a: ApiAlbum = list[i];
      if (a === null || a === undefined || typeof a.slug !== 'string') {
        continue;
      }
      const b = new AlbumBrief();
      b.slug = a.slug;
      b.name = typeof a.name === 'string' ? a.name : a.slug;
      b.subtitle = typeof a.subtitle === 'string' ? a.subtitle : '';
      b.coverUrl = typeof a.coverUrl === 'string' ? a.coverUrl : '';
      b.count = typeof a.count === 'number' ? a.count : 0;
      b.showOnHome = a.showOnHome === true;
      b.homeSlot = typeof a.homeSlot === 'number' ? a.homeSlot : 0;
      out.albums.push(b);
    }
    return out;
  }

  /**
   * 实时统计（失败返回 null）：已发布壁纸数 + 启用合辑数。
   * 后端直接数表，不是各合辑 count 相加（合辑间有重叠，daily 引用已有壁纸）。
   */
  static async fetchStats(): Promise<AppStats | null> {
    interface RawStats {
      wallpapers: number;
      albums: number;
    }
    const resp: ApiResponse<RawStats> = await HttpClient.get<RawStats>(ApiConfig.PATH.STATS);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return null;
    }
    const s = new AppStats();
    s.wallpapers = typeof resp.data.wallpapers === 'number' ? resp.data.wallpapers : 0;
    s.albums = typeof resp.data.albums === 'number' ? resp.data.albums : 0;
    return s;
  }

  /** 主色清单（失败返回空数组） */
  static async fetchColors(): Promise<ColorBrief[]> {
    interface RawColor {
      color: string;
      count: number;
    }
    const resp: ApiResponse<RawColor[]> = await HttpClient.get<RawColor[]>(ApiConfig.PATH.COLORS);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    const out: ColorBrief[] = [];
    const list: RawColor[] = resp.data;
    for (let i = 0; i < list.length; i++) {
      const r: RawColor = list[i];
      if (r === null || r === undefined || typeof r.color !== 'string' || r.color.length === 0) {
        continue;
      }
      // 丢弃编码损坏的颜色名（U+FFFD 等），避免渲染乱码 chip
      if (!isValidColorName(r.color)) {
        continue;
      }
      const c = new ColorBrief();
      c.color = r.color;
      c.count = typeof r.count === 'number' ? r.count : 0;
      out.push(c);
    }
    return out;
  }

  /**
   * 合辑内容（分页；可按主色 / 标签 / 关键词进一步筛选；失败返回空页）
   *
   * minLongEdge/minShortEdge：仅首页分区传（后端按「长边≥minLongEdge 且 短边≥minShortEdge」
   * 过滤低清图，从根源避免首页出现 350×260、498×1080 这类糊图）。传 0 表示不过滤。
   * keyword：服务端按标题/标签模糊匹配（2026-10-25 全库搜索，跨全部分页页生效）。
   */
  static async fetchAlbumPage(slug: string, page: number, pageSize: number,
    color: string = '', minLongEdge: number = 0, minShortEdge: number = 0,
    tag: string = '', keyword: string = ''): Promise<AlbumPage> {
    const out = new AlbumPage();
    out.slug = slug;
    if (slug.length === 0) {
      return out;
    }
    const query: Record<string, string> = {
      'page': String(page),
      'pageSize': String(pageSize)
    };
    if (color.length > 0) {
      query['color'] = color;
    }
    if (tag.length > 0) {
      query['tag'] = tag;
    }
    if (keyword.trim().length > 0) {
      query['keyword'] = keyword.trim();
    }
    if (minLongEdge > 0 && minShortEdge > 0) {
      query['minLongEdge'] = String(minLongEdge);
      query['minShortEdge'] = String(minShortEdge);
    }
    const path: string = `${ApiConfig.PATH.ALBUMS}/${slug}`;
    const resp: ApiResponse<ApiAlbumDetail> = await HttpClient.get<ApiAlbumDetail>(path, query);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return out;
    }
    const d: ApiAlbumDetail = resp.data;
    out.name = typeof d.name === 'string' ? d.name : slug;
    out.subtitle = typeof d.subtitle === 'string' ? d.subtitle : '';
    out.total = typeof d.total === 'number' ? d.total : 0;
    out.hasMore = d.hasMore === true;
    const list: ApiAlbumItem[] = d.list ?? [];
    for (let i = 0; i < list.length; i++) {
      const w: Wallpaper | null = AlbumsApi.toWallpaper(list[i]);
      if (w !== null) {
        out.items.push(w);
      }
    }
    return out;
  }

  /**
   * 每日精选往期列表（首页横向日期列表用）：最新在最前。
   *
   * 后端 `/albums/daily` 每项带 `date` / `issueNo`，真实历史 15 期。
   * 若后端以后只保留当天，返回长度 1 —— 调用方按「仅当天」隐藏往期行，
   * 不回退伪造日期（回溯数据必须显式标注，不能冒充真实精选）。
   */
  static async fetchDailyHistory(pageSize: number = 20): Promise<DailyHistoryItem[]> {
    const out: DailyHistoryItem[] = [];
    const query: Record<string, string> = {
      'page': '1',
      'pageSize': String(pageSize)
    };
    const resp: ApiResponse<ApiAlbumDetail> =
      await HttpClient.get<ApiAlbumDetail>(`${ApiConfig.PATH.ALBUMS}/daily`, query);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return out;
    }
    const list: ApiAlbumItem[] = resp.data.list ?? [];
    for (let i = 0; i < list.length; i++) {
      const it: ApiAlbumItem = list[i];
      const w: Wallpaper | null = AlbumsApi.toWallpaper(it);
      if (w === null) {
        continue;
      }
      const h = new DailyHistoryItem();
      h.issueNo = typeof it.issueNo === 'number' ? it.issueNo : 0;
      h.date = typeof it.date === 'string' ? it.date : '';
      h.imageUrl = it.imageUrl;
      h.wallpaper = w;
      out.push(h);
    }
    return out;
  }

  /** 后端合辑项 → Wallpaper（防御式：缺关键字段返回 null） */
  private static toWallpaper(a: ApiAlbumItem): Wallpaper | null {
    if (a === null || a === undefined || typeof a.imageUrl !== 'string' || a.imageUrl.length === 0) {
      return null;
    }
    const w = new Wallpaper();
    // 每日精选项没有壁纸 id：用负值区分，避免与真实壁纸 id 冲突（仅用于预览）
    const rawId: number = typeof a.id === 'number' ? a.id : -1;
    // 读时去重：dup 归一到 keep id，和 /wallpapers 目录保持同一套 id
    const sid: number = rawId > 0 ? DedupKeeps.keepOf(rawId) : rawId;
    w.serverId = sid;
    // id 与 /wallpapers 目录接口保持同一套规则（WallpaperApi.toWallpaper）：
    // 对应内置壁纸（description 有本地 id）沿用本地 id —— 否则同一条壁纸两个
    // 接口给出不同 id，收藏后「最爱收藏」按 id 匹配不上。
    const desc: string = (!DedupKeeps.isDup(rawId) && typeof a.description === 'string') ? a.description : '';
    w.id = desc.length > 0 ? desc
      : (rawId > 0) ? `c_${sid}` : `daily_${a.issueNo ?? 0}`;
    w.title = typeof a.title === 'string' ? a.title : '';
    w.category = (a.category !== null && a.category !== undefined) ? a.category.name : '';
    // tags 与 /wallpapers 保持同一逗号分隔模型：合辑详情此前恒空（标签筛选失效）
    const tagNames: string[] = [];
    if (a.tags !== null && a.tags !== undefined) {
      for (let i = 0; i < a.tags.length; i++) {
        const t: ApiTagRef = a.tags[i];
        if (t !== null && t !== undefined && typeof t.name === 'string') {
          tagNames.push(t.name);
        }
      }
    }
    w.tags = tagNames.join(',');
    const dom: string | null | undefined = a.dominantColor;
    w.dominantColor = (typeof dom === 'string') ? dom : '';
    w.width = typeof a.width === 'number' ? a.width : 0;
    w.height = typeof a.height === 'number' ? a.height : 0;
    w.orientation = (typeof a.orientation === 'string') ? a.orientation : '';
    // 角标数值只信任接口：非数字/负数/NaN 一律归 0（UI 侧 0 不渲染）
    w.viewCount = (typeof a.viewCount === 'number' && Number.isFinite(a.viewCount) && a.viewCount > 0)
      ? Math.floor(a.viewCount) : 0;
    w.downloadCount = (typeof a.downloadCount === 'number' && Number.isFinite(a.downloadCount) && a.downloadCount > 0)
      ? Math.floor(a.downloadCount) : 0;
    w.imageUrl = a.imageUrl;
    w.thumbUrl = (typeof a.thumbUrl === 'string' && a.thumbUrl.length > 0) ? a.thumbUrl : a.imageUrl;
    const when: string | null | undefined = a.date ?? a.publishedAt;
    if (typeof when === 'string') {
      const ts: number = Date.parse(when);
      w.uploadTime = Number.isFinite(ts) ? ts : 0;
    }
    return w;
  }

  /**
   * 每日精选关联的壁纸 → Wallpaper
   *
   * 与 toWallpaper 的区别：这里必须有真实的壁纸 id（用于 /wallpapers/:id/download 上报与保存），
   * 没有关联（wallpaper 为 null / id 非法）时返回 null，App 端大卡就只展示、不可点。
   */
  private static toLinkedWallpaper(a: ApiAlbumItem | null | undefined): Wallpaper | null {
    if (a === null || a === undefined) {
      return null;
    }
    const id: number = typeof a.id === 'number' ? a.id : 0;
    if (id <= 0 || typeof a.imageUrl !== 'string' || a.imageUrl.length === 0) {
      return null;
    }
    return AlbumsApi.toWallpaper(a);
  }
}
