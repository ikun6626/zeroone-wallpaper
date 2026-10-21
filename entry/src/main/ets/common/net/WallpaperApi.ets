import { Wallpaper } from '../../model/Wallpaper';
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

interface ApiWallpaper {
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
   */
  static async fetchPage(page: number, pageSize: number,
    categoryId: number = -1, sort: string = 'latest'): Promise<ApiResponse<WallpaperPage>> {
    const query: Record<string, string> = {
      'page': String(page),
      'pageSize': String(pageSize),
      'sort': sort
    };
    if (categoryId > 0) {
      query['categoryId'] = String(categoryId);
    }
    const resp: ApiResponse<ApiWallpaperPage> =
      await HttpClient.get<ApiWallpaperPage>(ApiConfig.PATH.WALLPAPERS, query);
    if (!resp.ok || resp.data === undefined) {
      const out: WallpaperPage = new WallpaperPage();
      return { ok: false, status: resp.status, code: resp.code, message: resp.message, data: out };
    }
    const out: WallpaperPage = new WallpaperPage();
    out.hasMore = resp.data.hasMore === true;
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
   */
  private static toWallpaper(a: ApiWallpaper): Wallpaper | null {
    if (a === null || a === undefined || typeof a.id !== 'number' || typeof a.title !== 'string') {
      return null;
    }
    const w = new Wallpaper();
    w.serverId = a.id;
    // 后端在 description 里记录了它对应的本地目录 id（seed 时写入）：
    // 沿用本地 id → 收藏记录跨数据源稳定；没有则是后台新增壁纸，用 c_ 前缀。
    const desc: string | null = a.description;
    w.id = (desc !== null && desc !== undefined && desc.length > 0) ? desc : `c_${a.id}`;
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
