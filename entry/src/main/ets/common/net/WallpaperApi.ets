import { Wallpaper } from '../../model/Wallpaper';
import { DedupKeeps } from '../constants/DedupKeeps';
import { ApiConfig } from './ApiConfig';
import { HttpClient, ApiResponse } from './HttpClient';

/**
 * 后端壁纸 JSON 结构（NestJS /api/v1/wallpapers 返回，仅取 App 需要的字段）
 */
interface ApiCategoryRef {
  id: number;
  name: string;
}

interface ApiTagRef {
  id: number;
  name: string;
}

/** 导出供 FavoriteApi 复用：/favorites/my 返回同构行，解析规则必须一致 */
export interface ApiWallpaper {
  id: number;
  title: string;
  description: string | null;
  imageUrl: string;
  thumbUrl: string | null;
  category: ApiCategoryRef | null;
  tags: ApiTagRef[];
  isFeatured: boolean;
  publishedAt: string | null;
  /** 后台图片分析脚本标注的主色桶（旧数据可能为空） */
  dominantColor?: string | null;
  width?: number;
  height?: number;
  orientation?: string | null;
  /** 浏览数（后台统计；旧数据可能缺失） */
  viewCount?: number;
  /** 下载/保存数（后台统计；旧数据可能缺失） */
  downloadCount?: number;
}

interface ApiWallpaperPage {
  list: ApiWallpaper[];
  total: number;
  page: number;
  pageSize: number;
  hasMore: boolean;
}

/**
 * 分页结果（把后端信封翻译成 App 内部结构）
 */
export class WallpaperPage {
  items: Wallpaper[] = [];
  hasMore: boolean = false;
  /** 后端返回的匹配总数（用于全库搜索结果条数显示；后端未返回时为 0） */
  total: number = 0;
}

/**
 * WallpaperApi —— 壁纸开放接口封装
 *
 * 统一职责：
 *  1. 拼 query（分页/分类/排序）请求 /api/v1/wallpapers；
 *  2. 把后端 JSON 安全地映射成 Wallpaper 模型（id → `c_<数字>`，防脏数据不抛错）；
 *  3. 上报下载 / 点赞（管理后台统计用）。
 */
export class WallpaperApi {
  /**
   * 拉取一页壁纸
   * @param page 页码（从 1 开始）
   * @param pageSize 每页条数（后端上限 50）
   * @param categoryId 可选：按分类过滤（后端数字分类 ID）
   * @param sort latest 最新（默认）/ hot 热门 / featured 精选
   * @param keyword 可选：关键词（服务端按标题/标签模糊匹配，2026-10-25 全库搜索）
   */
  static async fetchPage(page: number, pageSize: number,
    categoryId: number = -1, sort: string = 'latest',
    keyword: string = ''): Promise<ApiResponse<WallpaperPage>> {
    const query: Record<string, string> = {
      'page': String(page),
      'pageSize': String(pageSize),
      'sort': sort
    };
    if (categoryId > 0) {
      query['categoryId'] = String(categoryId);
    }
    const kw: string = keyword.trim();
    if (kw.length > 0) {
      query['keyword'] = kw;
    }
    const resp: ApiResponse<ApiWallpaperPage> =
      await HttpClient.get<ApiWallpaperPage>(ApiConfig.PATH.WALLPAPERS, query);
    if (!resp.ok || resp.data === undefined) {
      const out: WallpaperPage = new WallpaperPage();
      return { ok: false, status: resp.status, code: resp.code, message: resp.message, data: out };
    }
    const out: WallpaperPage = new WallpaperPage();
    out.hasMore = resp.data.hasMore === true;
    out.total = typeof resp.data.total === 'number' ? resp.data.total : 0;
    const rawList: ApiWallpaper[] = resp.data.list ?? [];
    for (let i = 0; i < rawList.length; i++) {
      const mapped: Wallpaper | null = WallpaperApi.toWallpaper(rawList[i]);
      if (mapped !== null) {
        out.items.push(mapped);
      }
    }
    return { ok: true, status: resp.status, data: out };
  }

  /** 上报一次下载（保存成功后调用，管理后台统计） */
  static async reportDownload(cloudId: number): Promise<void> {
    if (cloudId <= 0) {
      return;
    }
    await HttpClient.post<object>(`${ApiConfig.PATH.WALLPAPERS}/${cloudId}/download`);
  }

  /** 点赞 */
  static async like(cloudId: number): Promise<void> {
    if (cloudId <= 0) {
      return;
    }
    await HttpClient.post<object>(`${ApiConfig.PATH.WALLPAPERS}/${cloudId}/like`);
  }

  /**
   * 后端 JSON → Wallpaper 模型（防御式：字段缺失/类型不对返回 null，不让脏数据炸掉列表）
   * 公开静态方法：/favorites/my 的行与此同构，FavoriteApi 复用同一套解析保证 id 规则一致。
   */
  static toWallpaper(a: ApiWallpaper): Wallpaper | null {
    if (a === null || a === undefined || typeof a.id !== 'number' || typeof a.title !== 'string') {
      return null;
    }
    const w = new Wallpaper();
    // 读时去重：已知 pHash 重复组统一归一到 keep id，避免同一张图以两个 id 出现
    const sid: number = DedupKeeps.keepOf(a.id);
    w.serverId = sid;
    // 后端在 description 里记录了它对应的本地目录 id（seed 时写入）：
    // 沿用本地 id → 收藏记录跨数据源稳定；没有则是后台新增壁纸，用 c_ 前缀。
    const desc: string | null = a.description;
    w.id = (!DedupKeeps.isDup(a.id) && desc !== null && desc !== undefined && desc.length > 0)
      ? desc : `c_${sid}`;
    w.title = a.title;
    w.category = (a.category !== null && a.category !== undefined) ? a.category.name : '';
    w.author = 'ZeroOne';
    const pub: string | null = a.publishedAt;
    if (pub !== null && pub !== undefined) {
      const ts: number = Date.parse(pub);
      w.uploadTime = Number.isFinite(ts) ? ts : 0;
    }
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
    // 主色桶：后台图片分析脚本标注（用于颜色合辑与标签筛选；旧数据没有则不填）
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
    w.imageUrl = typeof a.imageUrl === 'string' ? a.imageUrl : '';
    w.thumbUrl = (a.thumbUrl !== null && a.thumbUrl !== undefined && typeof a.thumbUrl === 'string')
      ? a.thumbUrl : '';
    if (w.imageUrl.length === 0 && w.thumbUrl.length === 0) {
      // 没有任何远程图：无法展示，丢弃
      return null;
    }
    return w;
  }
}
