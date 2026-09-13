import { Wallpaper } from '../../model/Wallpaper';
import { CloudDBUtil } from '../utils/CloudDBUtil';
import { DefaultWallpapers } from '../constants/DefaultWallpapers';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { CloudStorageUtil } from '../utils/CloudStorageUtil';

/**
 * 缓存 DTO —— 只保留渲染必需字段
 *
 * 为什么不直接 JSON.stringify(Wallpaper)：
 *  1. Wallpaper 继承 cloudDatabase.DatabaseObject，基类内部字段不该被落盘；
 *  2. 更关键的是——Wallpaper.tagList / avgRating 是**原型上的 getter**，
 *     JSON.parse 得到的是纯对象，没有 getter，页面访问 item.tagList 会直接崩。
 *     所以必须显式做 DTO 往返，重新 new 出真正的 Wallpaper 实例。
 */
interface WallpaperDTO {
  id: string;
  title: string;
  imageUrl: string;
  thumbnailUrl: string;
  category: string;
  author: string;
  uploadTime: number;
  tags: string;
  /** 评分字段当前 UI 未使用，但属于云端 schema：一并缓存，避免将来回写云端时被清零 */
  ratingSum: number;
  ratingCount: number;
}

/**
 * StoreKeys —— 视图状态键（单一数据源契约）
 *
 * 页面只允许订阅这些 AppStorage 键，不得去读 Store 的私有字段：
 *  - 私有字段变化不会触发刷新（此前 hasMore()/isBusy() 就踩过这个坑），
 *    必须落成 AppStorage 键才会驱动 @StorageProp 重渲染。
 *  - 页面装饰器里要写字符串字面量（@StorageProp 只接受常量），
 *    因此这里的键名和页面里的写法必须逐字一致。
 */
export class StoreKeys {
  /** 壁纸列表 */
  static readonly LIST: string = 'wallpaperList';
  /** 首屏加载中（**仅在没有数据可展示时**为 true，用于骨架屏） */
  static readonly LOADING: string = 'wallpaperLoading';
  /** 分页加载中 */
  static readonly LOADING_MORE: string = 'wallpaperLoadingMore';
  /** 是否还有下一页；请求失败时必须保持 true，否则会永久锁死分页 */
  static readonly MORE: string = 'wallpaperMore';
  /** 最近一次请求失败（可重试） */
  static readonly ERROR: string = 'wallpaperError';
  /** 云端不可用，当前展示的是内置兜底数据 */
  static readonly OFFLINE: string = 'wallpaperOffline';
  /** 首屏数据来自本地缓存（可用于区分"秒开缓存"与"云端新鲜数据"） */
  static readonly FROM_CACHE: string = 'wallpaperFromCache';
}

/**
 * WallpaperStore —— 壁纸数据统一数据源（进程内单例）
 *
 * 三条铁律（对应交互审计中的 H2/H3）：
 *  1. **启动永不清空已展示数据**：先同步读本地缓存喂给 UI（秒开），再后台向云端刷新。
 *     此前 start() 无条件 setOrCreate([]) 会让每次冷启动先黑屏闪一下。
 *  2. **失败永不降级能力**：分页失败只暴露 ERROR 状态位，绝不把 MORE 置 false；
 *     网络抖动是瞬时的，一旦锁死用户只能杀进程。
 *  3. **状态必须可观察**：所有 loading/more/error 都落成 AppStorage 键，
 *     页面用 @StorageProp 订阅；Store 私有字段仅用于并发控制。
 *
 * 职责：
 *  - 冷启动首屏（start/refresh）：缓存秒开 → 分页查云库；
 *    空表 → 播种默认壁纸后按本地默认数据分页；云服务失败 → 内置数据兜底并标记离线。
 *  - 上拉分页（loadMore）：追加更早的数据并按 id 去重，写回 AppStorage('wallpaperList')。
 *  - 失败重试（retry）：无数据 → 重拉首屏；已有数据 → 重试下一页。
 */
export class WallpaperStore {
  /** 每页条数 */
  private static readonly PAGE_SIZE: number = 10;
  /**
   * 本地缓存最多保留条数
   * 一页足够实现"秒开首屏"，同时把 Preferences 的单个 value 控制在几 KB 以内。
   */
  private static readonly CACHE_MAX: number = 10;
  /** 缓存存储键 */
  private static readonly KEY_CACHE: string = 'wallpaper_cache_v1';

  private static instance: WallpaperStore | undefined = undefined;

  /** 首屏请求进行中（去重，防止入口重复触发） */
  private inFlight: Promise<Wallpaper[]> | undefined = undefined;
  /** 分页加载中（防重入） */
  private loadingMore: boolean = false;
  /** 云端分页游标：已取条数（query.limit 的 offset） */
  private cloudOffset: number = 0;
  /** 空表播种场景：分页直接切本地默认数据（云端此时也只有这批数据） */
  private seededLocal: Wallpaper[] | undefined = undefined;
  /** 离线兜底模式：云服务不可用，全量本地数据，不再分页 */
  private offline: boolean = false;

  /** 获取单例 */
  static getInstance(): WallpaperStore {
    if (WallpaperStore.instance === undefined) {
      WallpaperStore.instance = new WallpaperStore();
    }
    return WallpaperStore.instance;
  }

  // ==================== 启动 ====================

  /**
   * 入口启动：先同步喂缓存，再后台刷新（幂等）
   *
   * 顺序很关键：readCache() 是同步的（getPreferencesSync），
   * 所以首帧就有数据可渲染，不会出现"先黑屏再出图"。
   */
  start(): void {
    const cached: Wallpaper[] = this.readCache();
    AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, cached);
    AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, cached.length > 0);
    // 有缓存时后台静默刷新，不显示骨架屏；无缓存才需要 loading
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING, cached.length === 0);
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, false);
    AppStorage.setOrCreate<boolean>(StoreKeys.MORE, true);
    AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
    AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, false);
    this.refresh();
  }

  /** 确保首屏已加载（幂等；重复调用复用同一个 Promise） */
  async ensureLoaded(force: boolean = false): Promise<Wallpaper[]> {
    const cached: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    if (!force && cached.length > 0) {
      return cached;
    }
    if (this.inFlight !== undefined) {
      return this.inFlight;
    }
    this.inFlight = this.refresh();
    try {
      return await this.inFlight;
    } finally {
      this.inFlight = undefined;
    }
  }

  /** 首屏刷新：只在"无数据可展示"时才点亮骨架屏 */
  private async refresh(): Promise<Wallpaper[]> {
    const current: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING, current.length === 0);
    AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
    try {
      return await this.bootstrap();
    } finally {
      AppStorage.setOrCreate<boolean>(StoreKeys.LOADING, false);
    }
  }

  /**
   * 把记录里的"云存储路径"批量换成可加载的临时链接
   *
   * 缓存落盘的始终是原始路径（见 writeCache），临时链接只在内存里活 ——
   * 否则本地缓存与云数据库里会沉积一批过期链接，下次冷启动整屏加载失败。
   * 返回新数组，不改入参，保证原始路径不被覆盖。
   */
  private async resolveUrls(list: Wallpaper[]): Promise<Wallpaper[]> {
    const out: Wallpaper[] = [];
    for (let i = 0; i < list.length; i++) {
      const w: Wallpaper = list[i];
      const image: string = await CloudStorageUtil.urlFor(w.imageUrl);
      const thumb: string = await CloudStorageUtil.urlFor(w.thumbnailUrl);
      const copy: Wallpaper = new Wallpaper(w.id, w.title, image, thumb,
        w.category, w.author, w.uploadTime, w.tags);
      copy.ratingSum = w.ratingSum;
      copy.ratingCount = w.ratingCount;
      out.push(copy);
    }
    return out;
  }

  /** 首屏加载具体流程 */
  private async bootstrap(): Promise<Wallpaper[]> {
    let first: Wallpaper[] = [];
    try {
      first = await CloudDBUtil.queryWallpaperPage(WallpaperStore.PAGE_SIZE, 0);
    } catch (e) {
      // 云服务不可用（无网/未配置）：标记离线态供页面提示与重试，绝不黑屏
      console.error(`WallpaperStore cloud query failed, fallback to defaults: ${JSON.stringify(e)}`);
      this.offline = true;
      AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, true);
      AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, true);
      AppStorage.setOrCreate<boolean>(StoreKeys.MORE, false);
      const shown: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
      if (shown.length > 0) {
        // 已有缓存可展示：保留缓存内容，只标记离线。
        // 不要用内置数据把缓存"降级"掉——缓存里可能是更全的云端数据。
        AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, true);
        return shown;
      }
      AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, false);
      AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, DefaultWallpapers.ALL);
      // 兜底数据也落盘：下次冷启动至少能秒开，而不是又黑屏一次
      this.writeCache(DefaultWallpapers.ALL);
      return DefaultWallpapers.ALL;
    }

    this.offline = false;
    AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, false);

    let page: Wallpaper[];
    if (first.length === 0) {
      // 空表：播种默认壁纸，后续分页以本地默认数据为准
      try {
        await CloudDBUtil.batchInsert(DefaultWallpapers.ALL);
      } catch (e) {
        console.error(`WallpaperStore seed defaults failed: ${JSON.stringify(e)}`);
      }
      this.seededLocal = DefaultWallpapers.ALL;
      page = DefaultWallpapers.ALL.slice(0, WallpaperStore.PAGE_SIZE);
    } else {
      page = first;
    }
    this.cloudOffset = page.length;
    // 满页才可能有下一页；不满页直接到底
    AppStorage.setOrCreate<boolean>(StoreKeys.MORE, page.length === WallpaperStore.PAGE_SIZE);
    AppStorage.setOrCreate<boolean>(StoreKeys.FROM_CACHE, false);
    // 先按原始路径落盘缓存，再把链接解析好发布给界面（临时链接不落盘）
    this.writeCache(page);
    const shown: Wallpaper[] = await this.resolveUrls(page);
    AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, shown);
    return shown;
  }

  // ==================== 分页 ====================

  /**
   * 加载下一页（上拉触发）：结果追加进 AppStorage 并按 id 去重。
   * 没有更多/正在加载/离线时直接返回当前列表。
   */
  async loadMore(): Promise<Wallpaper[]> {
    const current: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    const more: boolean = AppStorage.get<boolean>(StoreKeys.MORE) ?? true;
    if (this.loadingMore || !more || this.offline) {
      return current;
    }
    this.loadingMore = true;
    AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, true);
    AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
    try {
      let page: Wallpaper[];
      if (this.seededLocal !== undefined) {
        page = this.seededLocal.slice(this.cloudOffset, this.cloudOffset + WallpaperStore.PAGE_SIZE);
      } else {
        page = await CloudDBUtil.queryWallpaperPage(WallpaperStore.PAGE_SIZE, this.cloudOffset);
      }
      // 只有"服务端明确返回不满一页"才认为到底
      if (page.length < WallpaperStore.PAGE_SIZE) {
        AppStorage.setOrCreate<boolean>(StoreKeys.MORE, false);
      }
      this.cloudOffset += page.length;
      const merged: Wallpaper[] = WallpaperStore.mergeDedup(current, page);
      // 已解析过的 http 链接会原样返回，只有新来的路径需要签发临时链接
      const resolved: Wallpaper[] = await this.resolveUrls(merged);
      AppStorage.setOrCreate<Wallpaper[]>(StoreKeys.LIST, resolved);
      return resolved;
    } catch (e) {
      // 关键修复：分页失败**不能**把 MORE 置 false。
      // 此前这里一旦失败就永久到底，用户恢复网络也无法继续翻页，只能杀进程重启。
      // 这里只暴露 ERROR 状态，由页面给出"点击重试"。
      console.error(`WallpaperStore loadMore failed: ${JSON.stringify(e)}`);
      AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, true);
      return current;
    } finally {
      this.loadingMore = false;
      AppStorage.setOrCreate<boolean>(StoreKeys.LOADING_MORE, false);
    }
  }

  /**
   * 失败重试入口（页面"点击重试"统一调这里）
   *  - 无数据（首屏失败）→ 重拉首屏
   *  - 离线兜底态 → 重新尝试连云端，成功则替换为云端数据
   *  - 已有数据（分页失败）→ 重试下一页
   */
  retry(): void {
    AppStorage.setOrCreate<boolean>(StoreKeys.ERROR, false);
    const current: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? [];
    if (current.length === 0 || this.offline) {
      this.offline = false;
      AppStorage.setOrCreate<boolean>(StoreKeys.OFFLINE, false);
      this.ensureLoaded(true);
      return;
    }
    this.loadMore();
  }

  /** 按 id 去重合并（换新数组引用，确保 @StorageProp 一定能刷到） */
  private static mergeDedup(current: Wallpaper[], page: Wallpaper[]): Wallpaper[] {
    const known: Set<string> = new Set<string>();
    for (const w of current) {
      known.add(w.id);
    }
    const merged: Wallpaper[] = current.slice();
    for (const w of page) {
      if (!known.has(w.id)) {
        merged.push(w);
      }
    }
    return merged;
  }

  // ==================== 本地缓存 ====================

  /** 读缓存（同步；失败/无缓存返回空数组，调用方自行决定是否显示骨架屏） */
  private readCache(): Wallpaper[] {
    if (!PreferenceUtil.isReady()) {
      return [];
    }
    const raw: string = PreferenceUtil.getString(WallpaperStore.KEY_CACHE, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const dtos: WallpaperDTO[] = JSON.parse(raw) as WallpaperDTO[];
      const out: Wallpaper[] = [];
      for (const d of dtos) {
        // 必须是真正的 Wallpaper 实例：tagList / avgRating 是原型 getter
        const w: Wallpaper = new Wallpaper(d.id, d.title, d.imageUrl, d.thumbnailUrl,
          d.category, d.author, d.uploadTime, d.tags);
        // 构造器不含评分字段，单独补回
        w.ratingSum = d.ratingSum;
        w.ratingCount = d.ratingCount;
        out.push(w);
      }
      return out;
    } catch (e) {
      console.error(`WallpaperStore readCache failed: ${JSON.stringify(e)}`);
      return [];
    }
  }

  /** 写缓存：只存首屏一页，控制 Preferences value 体积 */
  private writeCache(list: Wallpaper[]): void {
    if (!PreferenceUtil.isReady() || list.length === 0) {
      return;
    }
    const dtos: WallpaperDTO[] = [];
    const n: number = Math.min(list.length, WallpaperStore.CACHE_MAX);
    for (let i = 0; i < n; i++) {
      const w: Wallpaper = list[i];
      const dto: WallpaperDTO = {
        id: w.id,
        title: w.title,
        imageUrl: w.imageUrl,
        thumbnailUrl: w.thumbnailUrl,
        category: w.category,
        author: w.author,
        uploadTime: w.uploadTime,
        tags: w.tags,
        ratingSum: w.ratingSum,
        ratingCount: w.ratingCount
      };
      dtos.push(dto);
    }
    PreferenceUtil.setString(WallpaperStore.KEY_CACHE, JSON.stringify(dtos));
  }

  // ==================== 状态查询（兼容旧调用；页面优先订阅 AppStorage 键） ====================

  /**
   * 清除本地壁纸缓存（"清除缓存"入口调用）
   *
   * 只清缓存文件，**不动收藏**等用户资产（收藏是用户数据，清理缓存不该顺手删掉）。
   * 清完后当前内存列表保持不变，界面不会突然变空；下次冷启动才会重新拉取。
   */
  static clearCache(): void {
    PreferenceUtil.remove(WallpaperStore.KEY_CACHE);
  }

  /** 是否还有更多 */
  hasMore(): boolean {
    return AppStorage.get<boolean>(StoreKeys.MORE) ?? true;
  }
  /** 首屏或分页是否正在请求 */
  isBusy(): boolean {
    const loading: boolean = AppStorage.get<boolean>(StoreKeys.LOADING) ?? false;
    const loadingMore: boolean = AppStorage.get<boolean>(StoreKeys.LOADING_MORE) ?? false;
    return loading || loadingMore;
  }
}
