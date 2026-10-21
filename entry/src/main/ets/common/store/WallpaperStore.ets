import { Wallpaper } from '../../model/Wallpaper';
import { LocalWallpapers } from '../constants/LocalWallpapers';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { WallpaperApi } from '../net/WallpaperApi';
import { ApiConfig } from '../net/ApiConfig';

/**
 * StoreKeys —— 视图状态键（单一数据源契约）
 *
 * 页面只允许订阅这些 AppStorage 键，不得去读 Store 的私有字段：
 * 私有字段变化不会触发刷新，必须落成 AppStorage 键才会驱动 @StorageProp 重渲染。
 * 页面装饰器里要写字符串字面量（@StorageProp 只接受常量），
 * 因此这里的键名和页面里的写法必须逐字一致。
 *
 * 数据策略（云端优先 + 本地兜底 · 合并展示）：
 *  - 启动先同步发布内置目录（首帧秒开，295 张全部可见），随后异步拉取云端列表；
 *  - 云端成功 → 合并：云端独有的新壁纸排最前，本地目录顺序不变，
 *    同一张就地升级为云端高清版（id 不变，收藏不失效）；支持分页继续合并；
 *  - 云端失败（断网/服务不可用）→ 保留内置数据，OFFLINE=true 顶部提示。
 */
export class StoreKeys {
  /** 壁纸列表 */
  static readonly LIST: string = 'wallpaperList';
  /** 首屏加载中（云端首屏请求期间为 true，仅当本地兜底也无数据时页面才显示骨架屏） */
  static readonly LOADING: string = 'wallpaperLoading';
  /** 分页加载中 */
  static readonly LOADING_MORE: string = 'wallpaperLoadingMore';
  /** 是否还有下一页 */
  static readonly MORE: string = 'wallpaperMore';
  /** 最近一次失败（分页失败置 true，重试成功清零） */
  static readonly ERROR: string = 'wallpaperError';
  /** 离线兜底标识（正在展示内置壁纸时为 true） */
  static readonly OFFLINE: string = 'wallpaperOffline';
  /** 失败原因文本 */
  static readonly ERROR_TEXT: string = 'wallpaperErrorText';
  /** 是否来自本地兜底（= OFFLINE，保留键位兼容页面结构） */
  static readonly FROM_CACHE: string = 'wallpaperFromCache';
}

/**
 * WallpaperStore —— 壁纸数据统一数据源（进程内单例 · 云端优先）
 *
 * 保留的契约：
 *  - 页面只订阅 AppStorage 状态键（@StorageProp），不得读 Store 的私有字段；
 *  - start()/loadMore()/ensureLoaded()/retry() 保持原签名，页面调用点零改动。
 */
export class WallpaperStore {
  /** 旧版缓存键：只用于"清除缓存"时顺手清理历史数据 */
  private static readonly KEY_CACHE_LEGACY: string = 'wallpaper_cache_v1';

  private static instance: WallpaperStore | undefined = undefined;

  /** 获取单例 */
  static getInstance(): WallpaperStore {
    if (WallpaperStore.instance === undefined) {
      WallpaperStore.instance = new WallpaperStore();
    }
    return WallpaperStore.instance;
  }

  /** 本地兜底数据 */
  private static all(): Wallpaper[] {
    return LocalWallpapers.ALL;
  }

  /** 云端分页游标（下一页页码） */
  private page: number = 1;
  /** 是否正在拉取云端首屏 */
  private loadingCloud: boolean = false;
  /** 已拉取到的云端壁纸（首屏 + 各页累计，合并的唯一云端输入） */
  private cloudItems: Wallpaper[] = [];

  /**
   * 把云端数据合并进列表并发布：
   *  1. 云端独有（本地目录没有的新运营壁纸）排最前，保持云端分页顺序；
   *  2. 本地目录顺序不变，同 id 有云端版就用云端版（就地升级），否则保留本地版。
   */
  private mergeCloud(): void {
    const local: Wallpaper[] = LocalWallpapers.ALL;
    const localIds: Set<string> = new Set<string>();
    for (const w of local) {
      localIds.add(w.id);
    }
    const cloudById: Map<string, Wallpaper> = new Map<string, Wallpaper>();
    for (const w of this.cloudItems) {
      cloudById.set(w.id, w);
    }

    const result: Wallpaper[] = [];
    for (const c of this.cloudItems) {
      if (!localIds.has(c.id)) {
        result.push(c);
      }
    }
    for (const w of local) {
      const upgraded: Wallpaper | undefined = cloudById.get(w.id);
      result.push(upgraded !== undefined ? upgraded : w);
    }
    AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, result);
  }

  // ==================== 启动 ====================

  /**
   * 入口启动（幂等）：
   *  1. 同步发布内置目录 → 首帧即有内容（不白屏）；
   *  2. 异步拉取云端首屏 → 成功后整体替换（页面订阅 wallpaperList 自动刷新）。
   */
  start(): void {
    const local: Wallpaper[] = WallpaperStore.all();
    AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, local);
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING, false);
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, false);
    AppStorage.setOrCreate<boolean>(StoreKeys.MORE, true);
    AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
    AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, false);
    AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, '');
    AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, false);

    // 异步云端加载（fire-and-forget：结果通过 AppStorage 键广播给页面）
    this.loadCloud();
  }

  /**
   * 拉取云端首屏（内部方法）。
   * 成功 → 用云端列表替换 + MORE=hasMore；失败 → 保留当前数据 + 置 OFFLINE。
   */
  private async loadCloud(): Promise<void> {
    if (this.loadingCloud) {
      return;
    }
    this.loadingCloud = true;
    try {
      const resp = await WallpaperApi.fetchPage(1, ApiConfig.PAGE_SIZE);
      if (resp.ok && resp.data !== undefined && resp.data.items.length > 0) {
        this.page = 1;
        this.cloudItems = resp.data.items.slice();
        this.mergeCloud();
        AppStorage.setOrCreate<boolean>(StoreKeys.MORE, resp.data.hasMore);
        AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, false);
        AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, false);
        AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
        AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, '');
      } else if (resp.ok && resp.data !== undefined && resp.data.items.length === 0) {
        // 云端可达但后台还没有上架内容：保持内置兜底，不打扰用户
        this.cloudItems = [];
        AppStorage.setOrCreate<boolean>(StoreKeys.MORE, false);
        AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, true);
        AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, true);
        AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, '云端暂无内容');
      } else {
        // 网络失败：保留本地兜底
        AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, true);
        AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, true);
        AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, resp.code ?? 'NETWORK_ERROR');
      }
    } finally {
      this.loadingCloud = false;
    }
  }

  /** 确保首屏已加载（幂等；已有数据直接返回） */
  async ensureLoaded(force: boolean = false): Promise<Wallpaper[]> {
    const current: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    if (!force && current.length > 0) {
      return current;
    }
    this.start();
    return AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
  }

  // ==================== 分页 ====================

  /**
   * 加载下一页（云端分页；已到末页/离线兜底时为空操作）
   *
   * 并发保护：isBusy() 时直接返回；追加时按 id 去重，失败置 ERROR（列表底部显示重试）。
   */
  async loadMore(): Promise<Wallpaper[]> {
    const more: boolean = AppStorage.get<boolean>(StoreKeys.MORE) ?? false;
    const offline: boolean = AppStorage.get<boolean>(StoreKeys.OFFLINE) ?? false;
    if (!more || offline || this.isBusy() || this.loadingCloud) {
      return AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    }
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, true);
    try {
      const resp = await WallpaperApi.fetchPage(this.page + 1, ApiConfig.PAGE_SIZE);
      if (resp.ok && resp.data !== undefined) {
        this.page = this.page + 1;
        // 累计云端条目（按后端 serverId 去重，防重试重复），再统一合并发布
        const seenServer: Set<number> = new Set<number>();
        for (const w of this.cloudItems) {
          if (w.serverId > 0) {
            seenServer.add(w.serverId);
          }
        }
        for (const w of resp.data.items) {
          if (w.serverId > 0 && !seenServer.has(w.serverId)) {
            seenServer.add(w.serverId);
            this.cloudItems.push(w);
          } else if (w.serverId <= 0) {
            this.cloudItems.push(w);
          }
        }
        this.mergeCloud();
        AppStorage.setOrCreate<boolean>(StoreKeys.MORE, resp.data.hasMore);
        AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
        AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, '');
      } else {
        // 分页失败：保持 MORE=true（不锁死），列表底部给重试入口
        AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, true);
        AppStorage.setOrCreate<string>(StoreKeys.ERROR_TEXT, resp.code ?? 'NETWORK_ERROR');
      }
    } finally {
      AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, false);
    }
    return AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
  }

  /**
   * 重试入口（页面"点击重试"统一调这里）
   * 离线兜底 → 重新尝试云端首屏；分页失败 → 重新加载下一页。
   */
  retry(): void {
    const offline: boolean = AppStorage.get<boolean>(StoreKeys.OFFLINE) ?? false;
    if (offline) {
      this.loadCloud();
      return;
    }
    this.loadMore();
  }

  // ==================== 缓存清理 ====================

  /**
   * 清除本地缓存（"清除缓存"入口调用）
   *
   * 这里只清理旧版本残留的缓存键，**不动收藏**等用户资产
   * （收藏是用户数据，清理缓存不该顺手删掉）。
   */
  static clearCache(): void {
    if (PreferenceUtil.isReady()) {
      PreferenceUtil.remove(WallpaperStore.KEY_CACHE_LEGACY);
    }
  }

  // ==================== 状态查询 ====================

  /** 是否还有更多 */
  hasMore(): boolean {
    return AppStorage.get<boolean>(StoreKeys.MORE) ?? false;
  }

  /** 首屏或分页是否正在请求 */
  isBusy(): boolean {
    const loading: boolean = AppStorage.get<boolean>(StoreKeys.LOADING) ?? false;
    const loadingMore: boolean = AppStorage.get<boolean>(StoreKeys.LOADING_MORE) ?? false;
    return loading || loadingMore;
  }
}
