import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';

/**
 * PreferenceUtil —— 本地收藏工具
 *
 * 职责（全部本地持久化，无需登录）：
 *  收藏：把"收藏的壁纸 ID 列表"存为 JSON 字符串数组，如 ["w1","w2"]
 *
 * 使用前必须调用 init() 传入上下文（推荐在 Index 页面 aboutToAppear 里调用）：
 *   PreferenceUtil.init(getContext(this));
 */
export class PreferenceUtil {
  /** 收藏列表存储键 */
  private static readonly KEY_FAVORITES: string = 'favorite_wallpaper_ids';
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
      try {
        PreferenceUtil.favCache = JSON.parse(raw) as string[];
      } catch (e) {
        PreferenceUtil.favCache = [];
      }
    }
    return PreferenceUtil.favCache;
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
