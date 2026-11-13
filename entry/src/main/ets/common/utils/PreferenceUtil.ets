import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { Wallpaper } from '../../model/Wallpaper';
import { LocalWallpapers } from '../constants/LocalWallpapers';

/**
 * PreferenceUtil —— 本地收藏工具
 *
 * 职责（全部本地持久化，无需登录）：
 *  收藏：把"收藏的壁纸 ID 列表"存为 JSON 字符串数组，如 ["w1","w2"]
 *  收藏快照：收藏时顺手存下壁纸对象（JSON），「最爱收藏」展示时
 *   目录里找不到的（云端分页未拉到的图）用快照兜底展示
 *
 * 使用前必须调用 init() 传入上下文（推荐在 Index 页面 aboutToAppear 里调用）：
 *   PreferenceUtil.init(getContext(this));
 */
export class PreferenceUtil {
  /** 收藏列表存储键 */
  private static readonly KEY_FAVORITES: string = 'favorite_wallpaper_ids';
  /** 收藏快照存储键（收藏时记录的壁纸对象，数组按收藏时间倒序） */
  private static readonly KEY_FAV_ITEMS: string = 'favorite_items_v1';
  /**
   * 收藏发生变化的通知回调（2026-10-25 收藏云同步用）。
   * FavoriteSync.init() 注册；PreferenceUtil 不 import 网络层，避免循环依赖。
   * toggleFavoriteItem（用户操作）会触发；ensureFavorite（云端拉回）不触发。
   */
  static onFavoriteChanged: ((id: string, item: Wallpaper | undefined, added: boolean) => void) | null = null;
  /**
   * 收藏在 AppStorage 中的镜像键（跨 Tab 单一数据源）
   *
   * 为什么要有它：收藏此前是"每个页面各自 getFavoriteIds() 读一次"，
   * 而四个 Tab 页在切换时并不会重新走 aboutToAppear →
   * 在首页收藏后切到"我的"，收藏数还是旧的（审计 L3）。
   * 现在所有写入都广播到 AppStorage，页面用 @StorageProp('favoriteIds') 订阅即可。
   */
  static readonly APP_KEY_FAVORITES: string = 'favoriteIds';
  /** Preferences 存储文件名 */
  private static readonly STORE_NAME: string = 'zeroone_wallpaper_store';
  /** 缓存的上下文 */
  private static appContext: common.UIAbilityContext | undefined = undefined;
  /** 缓存的 Preferences 实例（懒加载） */
  private static prefs: preferences.Preferences | undefined = undefined;
  /** 收藏 ID 内存缓存（undefined = 尚未从磁盘加载），避免每次查询都 JSON.parse */
  private static favCache: string[] | undefined = undefined;

  /**
   * 初始化（幂等，可多次调用）
   * @param context UIAbility 上下文
   */
  static init(context: common.UIAbilityContext): void {
    if (PreferenceUtil.appContext === undefined) {
      PreferenceUtil.appContext = context;
    }
    // 预热收藏缓存并广播到 AppStorage（Index 入口调用，早于各页面读取）
    PreferenceUtil.favorites();
    PreferenceUtil.publishFavorites();
  }

  /** 把收藏列表同步到 AppStorage（换新数组引用，确保订阅者一定收到变更） */
  private static publishFavorites(): void {
    AppStorage.setOrCreate<string[]>(PreferenceUtil.APP_KEY_FAVORITES,
      PreferenceUtil.favorites().slice());
  }

  /** 获取（并懒加载）Preferences 实例 */
  private static getPrefs(): preferences.Preferences {
    if (PreferenceUtil.prefs === undefined) {
      const ctx: common.UIAbilityContext | undefined = PreferenceUtil.appContext;
      if (ctx === undefined) {
        throw new Error('PreferenceUtil 未初始化：请先调用 PreferenceUtil.init(context)');
      }
      PreferenceUtil.prefs = preferences.getPreferencesSync(ctx, { name: PreferenceUtil.STORE_NAME });
    }
    return PreferenceUtil.prefs;
  }

  /** 通用写入：先写内存实例，再异步 flush 落盘，不阻塞 UI 线程 */
  private static write(key: string, value: string): void {
    PreferenceUtil.getPrefs().putSync(key, value);
    PreferenceUtil.getPrefs().flush().catch((err: BusinessError) => {
      console.error(`PreferenceUtil flush failed: ${JSON.stringify(err)}`);
    });
  }

  // ==================== 收藏 ====================

  /**
   * 获取收藏列表（单一事实源 = 内存缓存；首次访问时从磁盘加载一次）。
   * 返回内部数组引用，仅类内部使用：toggle 直接改它后整体持久化。
   */
  private static favorites(): string[] {
    if (PreferenceUtil.favCache === undefined) {
      const raw: string = PreferenceUtil.getPrefs()
        .getSync(PreferenceUtil.KEY_FAVORITES, '[]') as string;
      let parsed: string[] = [];
      try {
        parsed = JSON.parse(raw) as string[];
      } catch (e) {
        parsed = [];
      }
      const migrated: string[] = PreferenceUtil.migrateDedupAliases(parsed);
      PreferenceUtil.favCache = migrated;
      // 淘汰的重复图 id 迁移到保留 id：需要落盘，避免下次启动又读回旧 id
      let dirty: boolean = migrated.length !== parsed.length;
      for (let i = 0; i < migrated.length && !dirty; i++) {
        dirty = migrated[i] !== parsed[i];
      }
      if (dirty) {
        PreferenceUtil.write(PreferenceUtil.KEY_FAVORITES, JSON.stringify(migrated));
      }
    }
    return PreferenceUtil.favCache;
  }

  /**
   * 收藏 id 的重复图别名迁移：淘汰 id → 保留 id，并去掉合并后的重复项。
   * 只改本地收藏，不动云端收藏（云端按 serverId 表示，本批不涉及后端）。
   */
  private static migrateDedupAliases(ids: string[]): string[] {
    const out: string[] = [];
    let changed: boolean = false;
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const keep: string = LocalWallpapers.resolveId(id);
      if (keep !== id) {
        changed = true;
      }
      if (out.indexOf(keep) < 0) {
        out.push(keep);
      } else {
        changed = true;
      }
    }
    return changed ? out : ids;
  }

  /** 获取全部收藏的壁纸 ID（返回副本，外部修改不影响缓存） */
  static getFavoriteIds(): string[] {
    return PreferenceUtil.favorites().slice();
  }

  /** 判断某壁纸是否已收藏 */
  static isFavorite(id: string): boolean {
    return PreferenceUtil.favorites().includes(id);
  }

  /**
   * 切换收藏状态（直接更新内存缓存，再异步落盘）
   * @param id 壁纸 ID
   * @returns 切换后的收藏状态（true = 已收藏）
   */
  static toggleFavorite(id: string): boolean {
    const ids: string[] = PreferenceUtil.favorites();
    const idx: number = ids.indexOf(id);
    let added: boolean;
    if (idx >= 0) {
      ids.splice(idx, 1);
      added = false;
    } else {
      ids.push(id);
      added = true;
    }
    PreferenceUtil.write(PreferenceUtil.KEY_FAVORITES, JSON.stringify(ids));
    // 广播：所有订阅了 favoriteIds 的页面/组件立即同步（跨 Tab 一致）
    PreferenceUtil.publishFavorites();
    return added;
  }

  /**
   * 切换收藏（带快照登记，收藏入口统一用这个）
   *
   * 1. 快照：收藏时把壁纸对象存进 KEY_FAV_ITEMS，「最爱收藏」展示时
   *    该壁纸不在目录（云端分页没拉到）也能显示；
   * 2. 别名归一：历史版本从合辑详情收藏的云端壁纸记的是 `c_<serverId>`，
   *    而目录接口里同一张图的 id 是 description 里的本地 id —— 切换时把
   *    两种记录视为同一条，避免出现"取消不掉/重复收藏"。
   */
  static toggleFavoriteItem(id: string, item?: Wallpaper): boolean {
    // 云端壁纸的别名 id（仅当与主 id 不同时才需要归一）
    let alias: string = '';
    if (item !== undefined && item.serverId > 0) {
      const a: string = `c_${item.serverId}`;
      if (a !== id) {
        alias = a;
      }
    }
    const ids: string[] = PreferenceUtil.favorites().slice();
    const hadId: boolean = ids.indexOf(id) >= 0;
    const hadAlias: boolean = alias.length > 0 && ids.indexOf(alias) >= 0;
    const added: boolean = !hadId && !hadAlias;
    // 清掉主 id 与别名（幂等），再按目标状态写入主 id
    const next: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const x: string = ids[i];
      if (x !== id && x !== alias) {
        next.push(x);
      }
    }
    if (added) {
      next.push(id);
    }
    PreferenceUtil.favCache = next;
    PreferenceUtil.write(PreferenceUtil.KEY_FAVORITES, JSON.stringify(next));
    PreferenceUtil.publishFavorites();

    // 快照登记：移除 id/alias 的旧快照，收藏时把当前对象记到最前
    const snaps: Wallpaper[] = PreferenceUtil.getFavoriteItems();
    const kept: Wallpaper[] = [];
    for (let i = 0; i < snaps.length; i++) {
      const w: Wallpaper = snaps[i];
      if (w.id !== id && (alias.length === 0 || w.id !== alias)) {
        kept.push(w);
      }
    }
    if (added && item !== undefined) {
      kept.unshift(item);
    }
    PreferenceUtil.setString(PreferenceUtil.KEY_FAV_ITEMS, JSON.stringify(kept));
    // 通知云同步（登录态下增量上/下云；游客态无人监听，回调为空）
    if (PreferenceUtil.onFavoriteChanged !== null) {
      PreferenceUtil.onFavoriteChanged(id, item, added);
    }
    return added;
  }

  /**
   * 按目标状态设置收藏（幂等），供「状态可能滞后」的入口使用（如卡片爱心）。
   *
   * 为什么不能直接 toggle：卡片爱心如果没及时回显，用户会重复点击，
   * 而每次 toggle 都会翻转一次，最终可能「用户以为已收藏、实际已取消」。
   * 这里先读当前状态（含 c_<serverId> 别名），与目标一致时直接返回，不做任何写入。
   *
   * @param favorite true = 收藏 / false = 取消
   * @returns 操作后的实际收藏状态
   */
  static setFavoriteItem(id: string, item: Wallpaper | undefined, favorite: boolean): boolean {
    let alias: string = '';
    if (item !== undefined && item.serverId > 0) {
      const a: string = `c_${item.serverId}`;
      if (a !== id) {
        alias = a;
      }
    }
    const ids: string[] = PreferenceUtil.favorites();
    const has: boolean = ids.indexOf(id) >= 0 || (alias.length > 0 && ids.indexOf(alias) >= 0);
    if (has === favorite) {
      return has;
    }
    return PreferenceUtil.toggleFavoriteItem(id, item);
  }

  /**
   * 并集添加收藏（不触发云回调）：云端收藏拉回本地时用（FavoriteSync）。
   * 已收藏时补登记快照（老收藏可能没有快照，补上「最爱收藏」才能展示），返回 false；
   * 新收藏返回 true 并登记到列表末尾（不改变现有收藏顺序）。
   */
  static ensureFavorite(id: string, item?: Wallpaper): boolean {
    const ids: string[] = PreferenceUtil.favorites();
    const snaps: Wallpaper[] = PreferenceUtil.getFavoriteItems();
    const had: boolean = ids.indexOf(id) >= 0;
    if (!had) {
      ids.push(id);
      PreferenceUtil.write(PreferenceUtil.KEY_FAVORITES, JSON.stringify(ids));
    }
    let snapChanged: boolean = false;
    let hasSnap: boolean = false;
    for (let i = 0; i < snaps.length; i++) {
      if (snaps[i].id === id) {
        hasSnap = true;
        break;
      }
    }
    if (!hasSnap && item !== undefined) {
      snaps.unshift(item);
      snapChanged = true;
    }
    if (!had || snapChanged) {
      if (snapChanged) {
        PreferenceUtil.setString(PreferenceUtil.KEY_FAV_ITEMS, JSON.stringify(snaps));
      }
      PreferenceUtil.publishFavorites();
    }
    return !had;
  }

  /**
   * 读取收藏快照（真实 Wallpaper 实例数组；JSON 解析失败/字段异常逐条跳过）
   * 必须重建实例而不是强转：普通对象没有类原型，ImagePreview 里的 getter 会炸。
   */
  static getFavoriteItems(): Wallpaper[] {
    const raw: string = PreferenceUtil.getString(PreferenceUtil.KEY_FAV_ITEMS, '[]');
    try {
      const arr: Wallpaper[] = JSON.parse(raw) as Wallpaper[];
      const out: Wallpaper[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o: Wallpaper | null = arr[i] ?? null;
        if (o === null || typeof o.id !== 'string' || o.id.length === 0) {
          continue;
        }
        const w = new Wallpaper();
        w.id = LocalWallpapers.resolveId(o.id);
        if (out.some((x: Wallpaper) => x.id === w.id)) {
          continue;   // 淘汰 id 与保留 id 的快照合并后只保留一条
        }
        w.title = typeof o.title === 'string' ? o.title : '';
        w.category = typeof o.category === 'string' ? o.category : '';
        w.dominantColor = typeof o.dominantColor === 'string' ? o.dominantColor : '';
        w.author = typeof o.author === 'string' ? o.author : '';
        w.tags = typeof o.tags === 'string' ? o.tags : '';
        w.imageUrl = typeof o.imageUrl === 'string' ? o.imageUrl : '';
        w.thumbUrl = typeof o.thumbUrl === 'string' ? o.thumbUrl : '';
        w.uploadTime = typeof o.uploadTime === 'number' ? o.uploadTime : 0;
        w.serverId = typeof o.serverId === 'number' ? o.serverId : -1;
        w.ratingSum = typeof o.ratingSum === 'number' ? o.ratingSum : 0;
        w.ratingCount = typeof o.ratingCount === 'number' ? o.ratingCount : 0;
        out.push(w);
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 获取收藏数量 */
  static getFavoriteCount(): number {
    return PreferenceUtil.favorites().length;
  }

  // ==================== 通用字符串 KV（供轻量本地缓存使用） ====================

  /** 是否已初始化（未初始化时缓存读写应直接跳过，而不是抛错） */
  static isReady(): boolean {
    return PreferenceUtil.appContext !== undefined;
  }

  /**
   * 读取字符串型配置（不存在或未初始化时返回默认值）
   *
   * 注意：Preferences 单个 value 建议控制在 8KB 以内，
   * 因此调用方只应缓存"首屏一页"这类小数据（见 WallpaperStore.CACHE_MAX）。
   */
  static getString(key: string, def: string): string {
    if (!PreferenceUtil.isReady()) {
      return def;
    }
    try {
      return PreferenceUtil.getPrefs().getSync(key, def) as string;
    } catch (e) {
      console.error(`PreferenceUtil getString failed: ${JSON.stringify(e)}`);
      return def;
    }
  }

  /** 写入字符串型配置（写内存 + 异步落盘，不阻塞 UI 线程） */
  static setString(key: string, value: string): void {
    if (!PreferenceUtil.isReady()) {
      return;
    }
    try {
      PreferenceUtil.write(key, value);
    } catch (e) {
      console.error(`PreferenceUtil setString failed: ${JSON.stringify(e)}`);
    }
  }

  /** 删除某个键（供"清除缓存"使用；收藏等用户资产不在清理范围内） */
  static remove(key: string): void {
    if (!PreferenceUtil.isReady()) {
      return;
    }
    try {
      PreferenceUtil.getPrefs().deleteSync(key);
      PreferenceUtil.getPrefs().flush().catch((err: BusinessError) => {
        console.error(`PreferenceUtil flush failed: ${JSON.stringify(err)}`);
      });
    } catch (e) {
      console.error(`PreferenceUtil remove failed: ${JSON.stringify(e)}`);
    }
  }
}
