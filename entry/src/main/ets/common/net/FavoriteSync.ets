import { Wallpaper } from '../../model/Wallpaper';
import { ApiConfig } from './ApiConfig';
import { ApiResponse } from './HttpClient';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { StoreKeys } from '../store/WallpaperStore';
import { FavoriteApi, FavoritePage } from './FavoriteApi';

/**
 * FavoriteSync —— 收藏云同步协调器（2026-10-25「收藏并入账号」第二批）
 *
 * 职责（全部 fire-and-forget：云同步失败绝不影响本地收藏体验）：
 *  1. init() 在 Index 启动时向 PreferenceUtil 注册"收藏变化回调" ——
 *     登录态下本地每次收藏/取消，顺手同步到云端（增量，单条）；
 *  2. onLoginSync() 在 AuthManager.login 成功后调用 ——
 *     ① 本地收藏解析成后端 id，POST /favorites/batch 批量上云（幂等）；
 *     ② 分页拉取云端收藏并集合并回本地（换机/多设备的收藏不丢）。
 *
 * 依赖方向（无循环）：AuthManager → FavoriteSync → {FavoriteApi, PreferenceUtil, WallpaperStore}；
 * 登录态一律读 AppStorage 镜像（AuthManager 发布），不反向 import AuthManager。
 */
export class FavoriteSync {
  private static inited: boolean = false;
  /** 同一轮 onLoginSync 进行中标记（登录回调可能连发） */
  private static syncing: boolean = false;

  /** 启动时调用一次（幂等）：挂上收藏变化回调 */
  static init(): void {
    if (FavoriteSync.inited) {
      return;
    }
    FavoriteSync.inited = true;
    PreferenceUtil.onFavoriteChanged =
      (id: string, item: Wallpaper | undefined, added: boolean): void => {
        FavoriteSync.handleLocalToggle(id, item, added);
      };
  }

  /** 登录成功后调用（AuthManager.login 成功分支）：双向合并 */
  static onLoginSync(): void {
    if (FavoriteSync.syncing) {
      return;
    }
    FavoriteSync.syncing = true;
    FavoriteSync.pushLocalThenPullCloud().finally((): void => {
      FavoriteSync.syncing = false;
    });
  }

  /** 是否已登录：读 AuthManager 发布的 AppStorage 镜像（避免循环依赖） */
  private static isLoggedIn(): boolean {
    return AppStorage.get<boolean>(ApiConfig.APP_KEY_LOGGED_IN) ?? false;
  }

  /**
   * 本地收藏/取消的增量同步（仅登录态）。
   * 纯本地壁纸（cloudId<=0，如离线兜底且云端没有对应行）不上云 ——
   * 它们在云端目录合并出对应行后，下次登录的批量合并会补上。
   */
  private static handleLocalToggle(id: string, item: Wallpaper | undefined, added: boolean): void {
    if (!FavoriteSync.isLoggedIn() || item === undefined) {
      return;
    }
    const cloudId: number = item.cloudId;
    if (cloudId <= 0) {
      return;
    }
    if (added) {
      FavoriteApi.add(cloudId).catch((): void => {});
    } else {
      FavoriteApi.remove(cloudId).catch((): void => {});
    }
  }

  /** 先推后拉：本地 → 云端批量合并，再云端 → 本地并集合并 */
  private static async pushLocalThenPullCloud(): Promise<void> {
    await FavoriteSync.pushLocalToCloud();
    await FavoriteSync.pullCloudToLocal();
  }

  /** 收集本地收藏能解析到的后端 id，分批上云 */
  private static async pushLocalToCloud(): Promise<void> {
    const ids: string[] = PreferenceUtil.getFavoriteIds();
    if (ids.length === 0) {
      return;
    }
    // 解析通道：当前壁纸目录（云端优先合并后的列表）+ 收藏快照
    const catalog: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    const snaps: Wallpaper[] = PreferenceUtil.getFavoriteItems();
    const byId: Map<string, Wallpaper> = new Map<string, Wallpaper>();
    for (let i = 0; i < catalog.length; i++) {
      byId.set(catalog[i].id, catalog[i]);
    }
    for (let i = 0; i < snaps.length; i++) {
      if (!byId.has(snaps[i].id)) {
        byId.set(snaps[i].id, snaps[i]);
      }
    }
    // 历史别名 c_<serverId> 也能解析（快照对象上 serverId 可用）
    const cloudIds: number[] = [];
    const seen: Set<number> = new Set<number>();
    for (let i = 0; i < ids.length; i++) {
      const fid: string = ids[i];
      const w: Wallpaper | undefined = byId.get(fid);
      const cloudId: number = w !== undefined
        ? w.cloudId
        : (fid.startsWith('c_') ? Number(fid.substring(2)) : -1);
      if (cloudId > 0 && !seen.has(cloudId)) {
        seen.add(cloudId);
        cloudIds.push(cloudId);
      }
    }
    if (cloudIds.length === 0) {
      return;
    }
    try {
      await FavoriteApi.batchAdd(cloudIds);
    } catch {
      // 上云失败：保留本地，下次登录重试
    }
  }

  /** 云端收藏并集合并回本地（只增不删，最多拉 10 页防失控） */
  private static async pullCloudToLocal(): Promise<void> {
    const pageSize: number = 50;
    for (let page: number = 1; page <= 10; page++) {
      let pageData: ApiResponse<FavoritePage> | null = null;
      try {
        pageData = await FavoriteApi.fetchMyPage(page, pageSize);
      } catch {
        return;
      }
      if (pageData === null || !pageData.ok || pageData.data === undefined) {
        return;
      }
      const items: Wallpaper[] = pageData.data.items;
      for (let i = 0; i < items.length; i++) {
        PreferenceUtil.ensureFavorite(items[i].id, items[i]);
      }
      if (!pageData.data.hasMore || items.length < pageSize) {
        return;
      }
    }
  }
}
