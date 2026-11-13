import { Wallpaper } from '../../model/Wallpaper';
import { ApiConfig } from './ApiConfig';
import { HttpClient, ApiResponse } from './HttpClient';
import { WallpaperApi, ApiWallpaper } from './WallpaperApi';

/** 后端「我的收藏」分页结构（与 /wallpapers 同构，list 为壁纸完整行） */
interface ApiFavoritePage {
  list: ApiWallpaper[];
  total: number;
  page: number;
  pageSize: number;
  hasMore: boolean;
}

/** 批量合并请求体（ArkTS 要求对象字面量必须有显式类型） */
interface BatchBody {
  wallpaperIds: number[];
}

/** 收藏分页结果（App 内部结构） */
export class FavoritePage {
  items: Wallpaper[] = [];
  total: number = 0;
  hasMore: boolean = false;
}

/**
 * FavoriteApi —— 用户收藏云接口封装（2026-10-25「收藏并入账号」第二批）
 *
 * 后端（Bearer 自动由 HttpClient 注入，未登录调用会拿到 401）：
 *   GET    /api/v1/favorites/my?page&pageSize   我的收藏（收藏时间倒序）
 *   POST   /api/v1/favorites/:wallpaperId       收藏一张（幂等）
 *   DELETE /api/v1/favorites/:wallpaperId       取消收藏（幂等）
 *   POST   /api/v1/favorites/batch              登录时批量合并本地收藏
 */
export class FavoriteApi {
  /** 拉一页我的收藏（复用 WallpaperApi 的解析：description→本地 id 规则一致，收藏不串号） */
  static async fetchMyPage(page: number, pageSize: number): Promise<ApiResponse<FavoritePage>> {
    const query: Record<string, string> = {
      'page': String(page),
      'pageSize': String(pageSize)
    };
    const resp: ApiResponse<ApiFavoritePage> =
      await HttpClient.get<ApiFavoritePage>(ApiConfig.PATH.FAVORITES_MY, query);
    const out: FavoritePage = new FavoritePage();
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return { ok: false, status: resp.status, code: resp.code, message: resp.message, data: out };
    }
    out.total = typeof resp.data.total === 'number' ? resp.data.total : 0;
    out.hasMore = resp.data.hasMore === true;
    const list: ApiWallpaper[] = resp.data.list ?? [];
    for (let i = 0; i < list.length; i++) {
      const mapped: Wallpaper | null = WallpaperApi.toWallpaper(list[i]);
      if (mapped !== null) {
        out.items.push(mapped);
      }
    }
    return { ok: true, status: resp.status, data: out };
  }

  /** 收藏一张（fire-and-forget 场景为主，失败静默：本地收藏不受影响） */
  static async add(cloudId: number): Promise<boolean> {
    if (cloudId <= 0) {
      return false;
    }
    const resp: ApiResponse<object> = await HttpClient.post<object>(`${ApiConfig.PATH.FAVORITES}/${cloudId}`);
    return resp.ok;
  }

  /** 取消收藏 */
  static async remove(cloudId: number): Promise<boolean> {
    if (cloudId <= 0) {
      return false;
    }
    const resp: ApiResponse<object> = await HttpClient.delete<object>(`${ApiConfig.PATH.FAVORITES}/${cloudId}`);
    return resp.ok;
  }

  /**
   * 登录时批量合并本地收藏（后端单次上限 200，这里自动分批）
   * @returns 是否全部批次成功（失败不影响本地，下次登录会再试）
   */
  static async batchAdd(cloudIds: number[]): Promise<boolean> {
    const ids: number[] = cloudIds.filter((v: number): boolean => v > 0);
    if (ids.length === 0) {
      return true;
    }
    let allOk: boolean = true;
    for (let start: number = 0; start < ids.length; start += 200) {
      const chunk: number[] = ids.slice(start, start + 200);
      const body: BatchBody = { wallpaperIds: chunk };
      const resp: ApiResponse<object> = await HttpClient.post<object>(ApiConfig.PATH.FAVORITES_BATCH, body);
      if (!resp.ok) {
        allOk = false;
      }
    }
    return allOk;
  }
}
