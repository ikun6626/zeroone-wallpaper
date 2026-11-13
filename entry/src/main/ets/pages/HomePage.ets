import { Wallpaper } from '../model/Wallpaper';
import { LocalWallpapers } from '../common/constants/LocalWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';
import { RemoteImage } from '../common/components/RemoteImage';
import { CardStatsOverlay } from '../common/components/CardStatsOverlay';
import { Haptics } from '../common/utils/Haptics';
import { AlbumsApi, AlbumPage, AlbumSection, ApiHomeComposition, AlbumBrief, ApiDailyCard, DailyHistoryItem } from '../common/net/AlbumsApi';
import { WallpaperApi } from '../common/net/WallpaperApi';
import { DailyApi, ApiDailyFeatured } from '../common/net/DailyApi';
import {
  cardAspect, HomeSeen, FeedPick, FeedState, FeedComposer,
  FeaturedPlan, FeaturedSelector, WallKeys, SkeletonRule, FeedKeyRule
} from '../common/home/HomeRules';
import { HomeRecommendApi, RecommendBatch } from '../common/home/HomeRecommend';
import { RecommendCursor } from '../common/home/HomeCursor';

/**
 * HomePage —— 首页 1.6.1（顶部日报区 → 动漫/写真横滑 → 精选 16 图 → 推荐无限流）
 *
 * 结构（单一 WaterFlow 作为整页滚动容器，sections 支持不同列数）：
 *   1) 顶部区：1 列 section —— 全宽日报大图(500vp) + Logo/搜索浮层 + 每日精选往期；
 *   2) 动漫/写真横滑：各占 1 列 section，位于精选 16 张之前；
 *   3) 精选区：1 列标题行（含「换一批」）+ 2 列 16 张（全部按日/批次轮换，只出现一次）；
 *   4) 推荐区：1 列「推荐」分隔行 + 2 列瀑布流（每批 20 张 + 1 张满宽占 2 格），
 *      满宽卡单独成 1 列 section，LazyForEach 懒加载。
 *
 * 降级优先级（任一步失败都不整页白屏）：
 *   顶部：home/composition.dailyFeatured → /daily/featured → 本地图；
 *   分类横滑：编排合辑 → /albums 补齐 → 本地分类；
 *   精选：始终来自本地目录（离线也可用，正好 16 张）；
 *   推荐：/wallpapers 兼容分页 → 本地精选兜底（不伪造阅读数/下载数）。
 *
 * 去重：serverId / 本地 id（含 DEDUP_ALIASES 归一）/ imageUrl / thumbUrl 四重键；
 * 精选与推荐互斥，推荐跨批不重复。
 */

/** 横滑卡的固定高度（vp）：高度统一、宽度按原图比例换算，行内基线始终对齐 */
const RAIL_CARD_H: number = 165;
/** 横滑卡宽度上下限：16:9 横图 = 165×1.78 ≈ 294 正好落在上限内，不会被裁 */
const RAIL_CARD_MIN_W: number = 96;
const RAIL_CARD_MAX_W: number = 300;

@Component
export struct HomePage {
  /** 打开/关闭全屏预览时隐藏/显示底部 Tab 栏 */
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /** 点分类横滑「更多 ›」：由 Index 处理（切到图库 tab 并打开该合辑详情） */
  onMore: (slug: string) => void = (_: string) => {};
  /** 首页搜索：由 Index 处理（写 AppStorage 请求并切到图库 tab 全库搜索） */
  onSearch: (keyword: string) => void = (_: string) => {};

  /** 日报头部（含浮层日期/期号） */
  @State daily: DailyHero = new DailyHero();
  /** 两组分类横滑 */
  @State rails: AlbumSection[] = [];
  /** 每日精选往期（横向日期列表，最新在最左） */
  @State dailyHistory: DailyHistoryItem[] = [];
  /** 新增模块：二次元（anime 合辑）、美女真人（无数据时隐藏）、最近（11.3 + 动漫） */
  @State animeRail: AlbumSection = new AlbumSection();
  @State beautyRail: AlbumSection = new AlbumSection();
  @State recentRail: AlbumSection = new AlbumSection();
  /** 精选 16 张 */
  @State featured: Wallpaper[] = [];
  /** 推荐流加载中（显示 3 个灰块骨架） */
  @State feedLoading: boolean = false;
  /** 推荐流失败（有已加载内容时显示「加载失败 · 重试」） */
  @State feedError: boolean = false;
  /** 推荐流是否还有下一页 */
  @State feedHasMore: boolean = true;
  /** 推荐降级为本地内容（不伪造接口成功） */
  @State feedOffline: boolean = false;
  /** 当前推荐轮次（一轮翻完后 +1，换 seed 续流） */
  @State feedRound: number = 0;
  /** 当前轮是否已完整翻完（允许开启下一轮） */
  @State feedRoundEnded: boolean = false;
  /** 回顶按钮可见 */
  @State showBackTop: boolean = false;
  /** 正在预览的壁纸 */
  @State previewItem: Wallpaper = new Wallpaper();
  /** 是否展示全屏预览 */
  @State previewVisible: boolean = false;
  /** 首屏滚动状态（用于判断用户是否真正滚动过） */
  @State userScrolled: boolean = false;

  /** 整页唯一滚动容器 */
  private scroller: Scroller = new Scroller();
  /** 顶部/精选/分隔/推荐统一数据源（WaterFlow 懒加载） */
  private ds: HomeDataSource = new HomeDataSource();
  /** 混合列数分段（顶部 1 列、精选/推荐 2 列、满宽卡 1 列） */
  private flowSections: WaterFlowSections = new WaterFlowSections();
  /** 当前条目快照 */
  private items: HomeItem[] = [];

  /** 推荐流自身去重 */
  private feedSeen: HomeSeen = new HomeSeen();
  /** 推荐需要排除的集合（日报 + 当前精选） */
  private feedExcluded: HomeSeen = new HomeSeen();
  /** 推荐已加载卡片 */
  private feedPicks: FeedPick[] = [];
  /** 满宽配额跨批状态 */
  private feedState: FeedState = new FeedState();
  /** 推荐游标（兼容 page + 预留 seed/offset） */
  private feedCursor: RecommendCursor = HomeRecommendApi.newCursor('2026-01-01');
  /** 单飞：禁止重复并发请求 */
  private feedInflight: boolean = false;
  /** 推荐卡唯一 key 序列（跨轮次单调递增；避免跨轮同 id 撞 LazyForEach key） */
  private feedSerial: number = 0;
  /** 失败节流时间戳（5s 内不自动重发） */
  private feedRetryAt: number = 0;

  /** 精选轮换批次（当日「换一批」次数） */
  private featuredBatchNo: number = 0;
  private featuredPlan: FeaturedPlan = new FeaturedPlan();
  /** 两组横滑之间的跨区去重 */
  private railSeen: string[] = [];
  /** 回顶自动淡出计时器 */
  private backTopTimer: number = -1;
  /** 日报是否已由编排接口确定（避免 /daily 兜底晚到覆盖） */
  private dailyLocked: boolean = false;

  aboutToAppear(): void {
    // 1) 先用本地内容把顶部/精选/分隔/骨架画出来（首屏不等网络）
    this.applyLocalDaily();
    this.initFeatured(false);
    this.rebuildItems();
    this.loadFeedFirstScreen();
    // 2) 顶部编排（日报 + 两组分类）异步填充，失败逐块降级
    this.loadTop();
  }

  // ==================== 顶部：日报 / 浮层 / 分类横滑 ====================

  /** 本地日报兜底：用一张非固定精选的本地图，日期/期号留空（不显示「第 0 期」） */
  private applyLocalDaily(): void {
    const d = new DailyHero();
    const w: Wallpaper | undefined = this.findLocalWallpaper('w113_7058e0dddcfa87eb8d7f42f61fa3e6a4');
    if (w !== undefined) {
      d.wallpaper = w;
      d.imageUrl = '';
    }
    this.daily = d;
  }

  /** 编排 → 日报；编排无日报再走 /daily/featured；都失败保留本地 */
  private loadTop(): void {
    AlbumsApi.fetchHomeComposition().then((c: ApiHomeComposition | null): void => {
      if (c !== null && c.daily !== null) {
        this.applyDailyCard(c.daily);
      } else {
        this.loadDailyFallback();
      }
      this.loadDailyHistory();
      // 优先级：日报 > 精选 > 最近 > 分类 rail > 推荐流。
      // 先装「最近」，再让分类 rail 避让；rail 到位后再清理推荐流里的同图。
      this.loadExtraModules((): void => {
        this.applyCompositionRails(c);
      });
    }).catch((): void => {
      this.loadDailyFallback();
      this.loadDailyHistory();
      this.loadExtraModules((): void => {
        this.useLocalRails();
      });
    });
  }

  private loadDailyFallback(): void {
    DailyApi.fetchLatest().then((d: ApiDailyFeatured | null): void => {
      if (d === null || this.dailyLocked) {
        return;
      }
      const hero = new DailyHero();
      hero.issueNo = d.issueNo;
      hero.dateText = this.fmtIsoDate(d.date);
      hero.imageUrl = d.imageUrl;
      const w = new Wallpaper(`daily_${hero.issueNo}`);
      w.serverId = d.wallpaperId !== null ? d.wallpaperId : -1;
      w.title = d.title;
      w.imageUrl = d.imageUrl;
      w.thumbUrl = d.imageUrl;
      hero.wallpaper = w;
      this.daily = hero;
      this.refreshFeedExcluded();
      this.reconcileAfterDaily();
    }).catch((): void => {
      // 保留本地兜底
    });
  }

  private applyDailyCard(c: ApiDailyCard): void {
    const hero = new DailyHero();
    hero.issueNo = c.issueNo;
    hero.dateText = this.fmtIsoDate(c.date);
    hero.imageUrl = c.imageUrl;
    if (c.wallpaper !== null) {
      hero.wallpaper = c.wallpaper;
    } else {
      const w = new Wallpaper(`daily_${c.issueNo}`);
      w.title = c.title;
      w.imageUrl = c.imageUrl;
      w.thumbUrl = c.imageUrl;
      w.serverId = -1;
      hero.wallpaper = w;
    }
    this.daily = hero;
    this.dailyLocked = true;
    this.refreshFeedExcluded();
    this.reconcileAfterDaily();
  }

  /**
   * 日报晚到后的全首页协调（问题 3）：
   *  1) 精选重算 —— 避开日报已占用的图，仍正好 16 张；
   *  2) 已加载推荐里与日报同图的条目立即移除（不是只影响未来批次）；
   *  3) 移除后触发一次补拉（在线）或本地补齐（离线），保证不出现同图。
   */
  private reconcileAfterDaily(): void {
    this.initFeatured(false);
    const dailySeen = new HomeSeen();
    if (this.daily.wallpaper !== undefined) {
      dailySeen.add(this.daily.wallpaper);
    }
    const kept: FeedPick[] = [];
    let removed: number = 0;
    for (let i = 0; i < this.feedPicks.length; i++) {
      const p: FeedPick = this.feedPicks[i];
      if (dailySeen.has(p.wallpaper)) {
        removed++;
      } else {
        kept.push(p);
      }
    }
    this.feedPicks = kept;
    this.rebuildItems();
    if (removed === 0) {
      return;
    }
    if (this.feedOffline) {
      this.appendLocalFeed(removed);
      return;
    }
    if (!this.feedHasMore && this.feedRoundEnded) {
      // 本轮已完整结束：换 seed 开下一轮，只补必要量
      this.startNextRound();
      return;
    }
    // 只补移除的数量；失败走既有节流/重试，不做无限重发
    this.loadFeed(true, 0, removed);
  }

  /** ISO 日期 →「11月7日」；无效返回空串（不渲染日期） */
  private fmtIsoDate(iso: string): string {
    if (iso.length === 0) {
      return '';
    }
    const ts: number = Date.parse(iso);
    if (!Number.isFinite(ts)) {
      return '';
    }
    const d: Date = new Date(ts);
    if (Number.isNaN(d.getTime())) {
      return '';
    }
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /**
   * 从编排拿两组上首页合辑；不足两组时用 /albums 补齐（不能重复同一合辑），
   * 仍不足则本地分类组兜底。
   */
  private applyCompositionRails(c: ApiHomeComposition | null): void {
    const briefs: AlbumBrief[] = [];
    if (c !== null) {
      for (let i = 0; i < c.albums.length && briefs.length < 2; i++) {
        const a: AlbumBrief = c.albums[i];
        if (a.slug === 'daily' || a.slug.length === 0) {
          continue;
        }
        let dup: boolean = false;
        for (let k = 0; k < briefs.length; k++) {
          if (briefs[k].slug === a.slug) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          briefs.push(a);
        }
      }
    }
    if (briefs.length >= 2) {
      this.startRails(briefs);
      return;
    }
    AlbumsApi.fetchAlbums().then((all: AlbumBrief[]): void => {
      for (let i = 0; i < all.length && briefs.length < 2; i++) {
        const a: AlbumBrief = all[i];
        if (a.slug === 'daily' || a.slug.length === 0) {
          continue;
        }
        let dup: boolean = false;
        for (let k = 0; k < briefs.length; k++) {
          if (briefs[k].slug === a.slug) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          briefs.push(a);
        }
      }
      if (briefs.length === 0) {
        this.useLocalRails();
      } else if (briefs.length === 1) {
        this.startRailsWithLocal(briefs);
      } else {
        this.startRails(briefs);
      }
    }).catch((): void => {
      if (briefs.length === 0) {
        this.useLocalRails();
      } else {
        this.startRailsWithLocal(briefs);
      }
    });
  }

  private startRails(briefs: AlbumBrief[]): void {
    this.railSeen = [];
    const next: AlbumSection[] = [];
    for (let i = 0; i < briefs.length && i < 2; i++) {
      const s = new AlbumSection();
      s.slug = briefs[i].slug;
      s.name = briefs[i].name;
      s.subtitle = briefs[i].subtitle;
      s.coverUrl = briefs[i].coverUrl;
      s.count = briefs[i].count;
      next.push(s);
    }
    this.rails = next;
    this.rebuildItems();
    this.loadRailAt(0);
  }
  private startRailsWithLocal(briefs: AlbumBrief[]): void {
    this.railSeen = [];
    const next: AlbumSection[] = [];
    const first = new AlbumSection();
    first.slug = briefs[0].slug;
    first.name = briefs[0].name;
    first.subtitle = briefs[0].subtitle;
    first.coverUrl = briefs[0].coverUrl;
    first.count = briefs[0].count;
    next.push(first);
    next.push(this.localRailSection('动物萌宠', 'local_0'));
    this.rails = next;
    this.rebuildItems();
    this.loadRailAt(0);
  }

  /** 完全离线：两组本地分类横滑 */
  private useLocalRails(): void {
    this.railSeen = [];
    const a: AlbumSection = this.localRailSection('自然风景', 'local_0');
    const b: AlbumSection = this.localRailSection('动物萌宠', 'local_1');
    // 两组之间仍跨区去重
    this.rails = [a, b];
    this.rebuildItems();
  }

  private localRailSection(category: string, slug: string): AlbumSection {
    const s = new AlbumSection();
    s.slug = slug;
    s.name = category;
    s.subtitle = '离线精选';
    const picked: Wallpaper[] = [];
    for (let i = 0; i < LocalWallpapers.ALL.length && picked.length < 8; i++) {
      const w: Wallpaper = LocalWallpapers.ALL[i];
      if (w.category !== category) {
        continue;
      }
      if (this.railSeenHas(w) || this.baseSeenHas(w)) {
        continue;
      }
      this.railSeenAdd(w);
      picked.push(w);
    }
    s.items = picked;
    s.loaded = true;
    return s;
  }

  /** 顺序加载两组（先到先占 url，保证两组之间不重复） */
  private loadRailAt(index: number): void {
    if (index >= this.rails.length) {
      return;
    }
    const s: AlbumSection = this.rails[index];
    if (s.slug.indexOf('local_') === 0) {
      this.loadRailAt(index + 1);
      return;
    }
    // 与旧首页一致：长边≥1440、短边≥900，过滤低清图
    AlbumsApi.fetchAlbumPage(s.slug, 1, 16, '', 1440, 900).then((p: AlbumPage): void => {
      const picked: Wallpaper[] = this.takeRailItems(p.items, 8);
      if (picked.length > 0) {
        this.applyRail(index, s.slug, picked);
      } else {
        this.applyRail(index, s.slug, this.localFill(s.name, 8));
      }
      this.loadRailAt(index + 1);
    }).catch((): void => {
      this.applyRail(index, s.slug, this.localFill(s.name, 8));
      this.loadRailAt(index + 1);
    });
  }

  private takeRailItems(list: Wallpaper[], limit: number): Wallpaper[] {
    const out: Wallpaper[] = [];
    for (let i = 0; i < list.length && out.length < limit; i++) {
      const w: Wallpaper = list[i];
      // rail 优先级低于日报/精选/最近：这些模块已占位的图不再进 rail
      if (this.railSeenHas(w) || this.baseSeenHas(w)) {
        continue;
      }
      this.railSeenAdd(w);
      out.push(w);
    }
    return out;
  }

  private railSeenHas(w: Wallpaper): boolean {
    const keys: string[] = WallKeys.of(w);
    for (let i = 0; i < keys.length; i++) {
      if (this.railSeen.indexOf(keys[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private railSeenAdd(w: Wallpaper): void {
    const keys: string[] = WallKeys.of(w);
    for (let i = 0; i < keys.length; i++) {
      if (this.railSeen.indexOf(keys[i]) < 0) {
        this.railSeen.push(keys[i]);
      }
    }
  }

  private localFill(category: string, limit: number): Wallpaper[] {
    const out: Wallpaper[] = [];
    for (let i = 0; i < LocalWallpapers.ALL.length && out.length < limit; i++) {
      const w: Wallpaper = LocalWallpapers.ALL[i];
      if (w.id.startsWith('my_') || w.category !== category) {
        continue;
      }
      if (this.railSeenHas(w) || this.baseSeenHas(w)) {
        continue;
      }
      this.railSeenAdd(w);
      out.push(w);
    }
    if (out.length === 0) {
      for (let i = 0; i < LocalWallpapers.ALL.length && out.length < limit; i++) {
        const w: Wallpaper = LocalWallpapers.ALL[i];
        if (w.id.startsWith('my_')) {
          continue;
        }
        if (this.railSeenHas(w)) {
          continue;
        }
        this.railSeenAdd(w);
        out.push(w);
      }
    }
    return out;
  }

  private applyRail(index: number, slug: string, items: Wallpaper[]): void {
    const next: AlbumSection[] = this.rails.slice();
    for (let i = 0; i < next.length; i++) {
      if (next[i].slug === slug) {
        const s = new AlbumSection();
        s.slug = next[i].slug;
        s.name = next[i].name;
        s.subtitle = next[i].subtitle;
        s.coverUrl = next[i].coverUrl;
        s.count = next[i].count;
        s.items = items;
        s.loaded = true;
        next[i] = s;
        break;
      }
    }
    this.rails = next;
    this.rebuildItems();
    // rail 优先级高于推荐流：新到位的 rail 图要把已加载推荐里的同图挤掉并补量
    this.pruneFeedConflicts();
  }

  // ==================== 新增模块：每日往期 / 二次元 / 美女真人 / 最近 ====================

  /** 加载每日精选往期（真实历史；线上仅当天时返回 1 条，往期行自动隐藏） */
  private loadDailyHistory(): void {
    AlbumsApi.fetchDailyHistory(20).then((list: DailyHistoryItem[]): void => {
      this.dailyHistory = list;
      this.pruneFeedConflicts();
    }).catch((): void => {
      this.dailyHistory = [];
    });
  }

  /** 构造一个已加载的分区 rail */
  private mkRail(slug: string, name: string, subtitle: string, items: Wallpaper[]): AlbumSection {
    const s = new AlbumSection();
    s.slug = slug;
    s.name = name;
    s.subtitle = subtitle;
    s.items = items;
    s.loaded = true;
    return s;
  }

  /**
   * 更高优先级的占位集合：日报 > 精选 > 最近。
   * 分类 rail 取图时必须避让这些图（rail 优先级在其之后）。
   */
  private baseSeenHas(w: Wallpaper): boolean {
    const seen = new HomeSeen();
    if (this.daily.wallpaper !== undefined) {
      seen.add(this.daily.wallpaper);
    }
    for (let i = 0; i < this.featured.length; i++) {
      seen.add(this.featured[i]);
    }
    for (let i = 0; i < this.dailyHistory.length; i++) {
      seen.add(this.dailyHistory[i].wallpaper);
    }
    for (let i = 0; i < this.recentRail.items.length; i++) {
      seen.add(this.recentRail.items[i]);
    }
    return seen.has(w);
  }

  /**
   * 加载「二次元 / 美女真人 / 最近」三个模块。
   *
   * 数据来源（2026-11-07 实测）：
   *  - 二次元：合辑 `anime`（417 张，真实存在）；
   *  - 美女真人：现有分类/标签/关键词均查不到真人女性内容，**不凭空造分类**，
   *    预留 slug `beauty`（后台建合辑后即有数据），当前 0 张 → UI 整块隐藏；
   *  - 真人：最新上架中**排除**动漫插画内容（类目/标签/标题命中「动漫」「二次元」），
   *    最多 12 张，不足 4 张整栏隐藏；不拿动漫图凑数。
   *
   * 完成后回调：分类 rail 需要避让「真人」，保证跨模块不重复。
   */
  private loadExtraModules(done: () => void): void {
    this.fetchRealPersonRail().then((recent: Wallpaper[]): void => {
      // 「真人」栏：最新上架中排除动漫插画内容；不足 4 张整栏隐藏（不拿动漫图凑数）
      this.recentRail = this.mkRail('recent', '写真', '最新上架', recent.length >= 4 ? recent : []);
      AlbumsApi.fetchAlbumPage('anime', 1, 16, '', 1440, 900).then((p: AlbumPage): void => {
        // 二次元 rail 避让日报/精选/往期/真人已占位的图
        const animeItems: Wallpaper[] = [];
        for (let i = 0; i < p.items.length; i++) {
          const w: Wallpaper = p.items[i];
          if (this.baseSeenHas(w) || this.railSeenHas(w)) {
            continue;
          }
          animeItems.push(w);
          this.railSeenAdd(w);
        }
        this.animeRail = this.mkRail('anime', '动漫', '动漫插画', animeItems.slice(0, 10));
        this.beautyRail = this.mkRail('beauty', '美女真人', '真人气质 · 暂无内容', []);
        // 三栏数据晚于首屏到达：强制重建条目/分区，保证精选之后的三栏立即出现
        this.rebuildItems();
        this.pruneFeedConflicts();
        done();
      }).catch((): void => {
        this.animeRail = new AlbumSection();
        this.beautyRail = this.mkRail('beauty', '美女真人', '', []);
        this.rebuildItems();
        this.pruneFeedConflicts();
        done();
      });
    }).catch((): void => {
      // 最新页失败：真人栏不展示伪造内容
      this.recentRail = new AlbumSection();
      this.animeRail = new AlbumSection();
      this.beautyRail = this.mkRail('beauty', '美女真人', '', []);
      this.rebuildItems();
      this.pruneFeedConflicts();
      done();
    });
  }

  /**
   * 「写真」栏数据：只收真人照片（标签命中 写真|人像|美女|少女），最多 12 张。
   * 服务端按关键词召回（已排除 帅哥/男生/情侣插画/动漫二次元），客户端再按标签复核；
   * 不足 4 张时整栏隐藏，不放宽条件凑数。
   */
  private async fetchRealPersonRail(): Promise<Wallpaper[]> {
    const out: Wallpaper[] = [];
    const picked = new HomeSeen();
    for (let page = 1; page <= 3 && out.length < 12; page++) {
      const resp = await WallpaperApi.fetchPage(page, 30, -1, 'latest', '写真');
      if (!resp.ok || resp.data === undefined) {
        break;
      }
      const items: Wallpaper[] = resp.data.items;
      if (items.length === 0) {
        break;
      }
      for (let i = 0; i < items.length && out.length < 12; i++) {
        const w: Wallpaper = items[i];
        if (!this.isRealPersonContent(w) || this.baseSeenHas(w) || picked.has(w)) {
          continue;
        }
        picked.add(w);
        out.push(w);
      }
    }
    return out;
  }

  /**
   * 真人照片判定：正向命中 写真|人像|美女|少女 且无男性/情侣/动漫标记。
   * 与后端 SEARCH_SYNONYMS 的「写真」规则保持同口径，客户端兜底防止脏数据混入。
   */
  private isRealPersonContent(w: Wallpaper): boolean {
    if (this.isAnimeContent(w)) {
      return false;
    }
    if (w.category.indexOf('情侣') >= 0) {
      return false;
    }
    const positive: string[] = ['写真', '人像', '美女', '少女'];
    const ts: string[] = w.tagList;
    let hit: boolean = false;
    for (let i = 0; i < ts.length; i++) {
      const t: string = ts[i];
      if (t.indexOf('帅哥') >= 0 || t.indexOf('男生') >= 0) {
        return false;
      }
      for (let j = 0; j < positive.length; j++) {
        if (t.indexOf(positive[j]) >= 0) {
          hit = true;
        }
      }
    }
    return hit;
  }

  /**
   * 动漫插画内容判定（合辑 `anime` 的近似：类目/标签/标题命中「动漫」「二次元」）。
   * 仅用于「真人」栏排除法，不改变其他模块的任何筛选逻辑。
   */
  private isAnimeContent(w: Wallpaper): boolean {
    const cat: string = w.category;
    if (cat.indexOf('动漫') >= 0 || cat.indexOf('二次元') >= 0) {
      return true;
    }
    const ts: string[] = w.tagList;
    for (let i = 0; i < ts.length; i++) {
      const t: string = ts[i];
      if (t.indexOf('动漫') >= 0 || t.indexOf('二次元') >= 0) {
        return true;
      }
    }
    const title: string = w.title;
    return title.indexOf('动漫') >= 0 || title.indexOf('二次元') >= 0;
  }

  /**
   * 已加载推荐流里与更高优先级模块（日报/精选/往期/最近/rail）同图的条目移除，
   * 并按移除量补拉（离线则本地补），避免低优先级的推荐流重复占位。
   */
  private pruneFeedConflicts(): void {
    this.refreshFeedExcluded();
    const kept: FeedPick[] = [];
    let removed: number = 0;
    for (let i = 0; i < this.feedPicks.length; i++) {
      const p: FeedPick = this.feedPicks[i];
      if (this.feedExcluded.has(p.wallpaper)) {
        removed++;
      } else {
        kept.push(p);
      }
    }
    if (removed === 0) {
      return;
    }
    this.feedPicks = kept;
    this.rebuildItems();
    if (this.feedOffline) {
      this.appendLocalFeed(removed);
      return;
    }
    if (!this.feedHasMore && this.feedRoundEnded) {
      this.startNextRound();
      return;
    }
    this.loadFeed(true, 0, removed);
  }

  private todayKey(): string {
    const d = new Date();
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const mm: string = m < 10 ? `0${m}` : String(m);
    const dd: string = day < 10 ? `0${day}` : String(day);
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  /**
   * 本地精选计划（始终 16 张）：
   * 当日首次 → 读取昨日轮换 ID 并避开；当日重进 → 沿用持久化批次号；
   * 点「换一批」→ 批次号 +1，且避开当前轮换。
   */
  private initFeatured(forceNewBatch: boolean): void {
    const all: Wallpaper[] = LocalWallpapers.ALL;
    const today: string = this.todayKey();
    const storedDate: string = PreferenceUtil.getString('home_feat_rot_date', '');
    const storedIdsRaw: string = PreferenceUtil.getString('home_feat_rot_ids', '');
    const prevIdsRaw: string = PreferenceUtil.getString('home_feat_prev_ids', '');

    let previous: string[] = this.splitIds(prevIdsRaw);
    let batch: number = 0;
    if (storedDate === today) {
      const b: string = PreferenceUtil.getString('home_feat_rot_batch', '0');
      const parsed: number = Number.parseInt(b);
      batch = Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
    } else if (storedIdsRaw.length > 0) {
      // 跨天：昨日轮换 ID 落盘，今天必须尽量与它不同
      previous = this.splitIds(storedIdsRaw);
      PreferenceUtil.setString('home_feat_prev_date', storedDate);
      PreferenceUtil.setString('home_feat_prev_ids', storedIdsRaw);
      batch = 0;
    }
    if (forceNewBatch) {
      previous = this.splitIds(this.featuredPlan.rotationIds.join(','));
      if (previous.length === 0) {
        previous = this.splitIds(storedIdsRaw);
      }
      batch = this.featuredBatchNo + 1;
    }

    const excluded = new HomeSeen();
    if (this.daily.wallpaper !== undefined) {
      excluded.add(this.daily.wallpaper);
    }
    excluded.addAll(this.feedPickWallpapers());

    const plan: FeaturedPlan = FeaturedSelector.select(all, today, previous, batch, excluded);
    this.featuredPlan = plan;
    this.featuredBatchNo = batch;
    this.featured = plan.items;
    this.refreshFeedExcluded();

    PreferenceUtil.setString('home_feat_rot_date', today);
    PreferenceUtil.setString('home_feat_rot_ids', plan.rotationIds.join(','));
    PreferenceUtil.setString('home_feat_rot_batch', String(batch));
  }

  private splitIds(raw: string): string[] {
    if (raw.length === 0) {
      return [];
    }
    const out: string[] = [];
    const parts: string[] = raw.split(',');
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) {
        out.push(p);
      }
    }
    return out;
  }

  private changeFeatured(): void {
    Haptics.light();
    // 16 个席位全部重算（整体替换 featured 数组），保证整屏图位都换
    this.initFeatured(true);
    this.rebuildItems();
  }

  // ==================== 推荐流 ====================

  private loadFeedFirstScreen(): void {
    this.feedCursor = HomeRecommendApi.newCursor(this.todayKey());
    this.loadFeed(false, 0);
  }

  /** 从已加载推荐里拼 Wallpaper 列表（用于互斥/预览池） */
  private feedPickWallpapers(): Wallpaper[] {
    const out: Wallpaper[] = [];
    for (let i = 0; i < this.feedPicks.length; i++) {
      out.push(this.feedPicks[i].wallpaper);
    }
    return out;
  }

  /** 推荐排除集合 = 日报 + 精选 + 每日往期 + 最近 + 分类 rail（按优先级高→低） */
  private refreshFeedExcluded(): void {
    const next = new HomeSeen();
    if (this.daily.wallpaper !== undefined) {
      next.add(this.daily.wallpaper);
    }
    next.addAll(this.featured);
    for (let i = 0; i < this.dailyHistory.length; i++) {
      next.add(this.dailyHistory[i].wallpaper);
    }
    for (let i = 0; i < this.recentRail.items.length; i++) {
      next.add(this.recentRail.items[i]);
    }
    for (let i = 0; i < this.rails.length; i++) {
      const items: Wallpaper[] = this.rails[i].items;
      for (let k = 0; k < items.length; k++) {
        next.add(items[k]);
      }
    }
    for (let i = 0; i < this.animeRail.items.length; i++) {
      next.add(this.animeRail.items[i]);
    }
    for (let i = 0; i < this.beautyRail.items.length; i++) {
      next.add(this.beautyRail.items[i]);
    }
    this.feedExcluded = next;
  }

  /**
   * 拉一批推荐（单飞 + 失败 5s 节流）。
   * @param force true=用户点重试/日报协调补拉（忽略节流与 hasMore 限制）
   * @param pagesTried 本次调用内已换页次数（去重后为空时最多再翻 2 页）
   * @param want 本次希望补入的卡片数（默认整批 20）
   */
  private loadFeed(force: boolean, pagesTried: number, want: number = FeedComposer.LIMIT): void {
    if (this.feedInflight) {
      return;
    }
    if (force) {
      // 用户手动重试：解除本项目前本地兜底的锁，允许再次请求真实接口
      if (this.feedOffline) {
        this.feedOffline = false;
        this.feedHasMore = true;
      }
    } else if (this.feedOffline) {
      return;
    }
    if (!this.feedHasMore && this.feedPicks.length > 0 && !force) {
      return;
    }
    const now: number = Date.now();
    if (!force && now < this.feedRetryAt) {
      return;
    }
    this.feedInflight = true;
    this.feedLoading = true;
    this.feedError = false;
    this.rebuildItems();

    HomeRecommendApi.fetchBatch(this.feedCursor).then((batch: RecommendBatch): void => {
      this.feedInflight = false;
      this.feedLoading = false;
      if (!batch.ok) {
        this.onFeedFailure();
        return;
      }
      this.feedCursor = batch.cursor;
      this.feedHasMore = batch.hasMore;
      this.feedRoundEnded = batch.roundComplete;
      this.refreshFeedExcluded();
      const picks: FeedPick[] = FeedComposer.compose(batch.items, this.feedSeen, this.feedExcluded, this.feedState, want);
      if (picks.length > 0) {
        this.assignFeedKeys(picks);
        for (let i = 0; i < picks.length; i++) {
          this.feedPicks.push(picks[i]);
        }
        this.feedError = false;
        this.rebuildItems();
        return;
      }
      // 本页全被去重过滤：还能翻页就再翻（最多 2 次，避免无限请求）
      if (batch.hasMore && pagesTried < 2) {
        this.loadFeed(false, pagesTried + 1, want);
        return;
      }
      if (!batch.hasMore && this.feedPicks.length === 0) {
        this.feedOffline = true;
        this.feedHasMore = false;
        this.feedRoundEnded = false;
        this.appendLocalFeed();
        return;
      }
      this.rebuildItems();
    }).catch((): void => {
      this.feedInflight = false;
      this.feedLoading = false;
      this.onFeedFailure();
    });
  }

  private onFeedFailure(): void {
    this.feedRetryAt = Date.now() + 5000;
    if (this.feedPicks.length === 0) {
      // 首批失败：先用本地精选兜底，页面留内容；底部仍给「加载失败 · 重试」
      this.feedOffline = true;
      this.feedHasMore = false;
      this.feedError = true;
      this.appendLocalFeed();
      return;
    }
    this.feedError = true;
    this.rebuildItems();
  }

  /** 推荐接口不可用：本地目录降级（角标沿用 0，不伪造数字） */
  private appendLocalFeed(want: number = FeedComposer.LIMIT): void {
    this.refreshFeedExcluded();
    const local = LocalWallpapers.ALL.slice();
    const picks: FeedPick[] = FeedComposer.compose(local, this.feedSeen, this.feedExcluded, this.feedState, want);
    this.assignFeedKeys(picks);
    for (let i = 0; i < picks.length; i++) {
      this.feedPicks.push(picks[i]);
    }
    this.rebuildItems();
  }

  /**
   * 为每个推荐条目分配跨轮次单调唯一的 key。
   * 不能沿用 `feed_${wallpaper.id}`：换 seed 后同一 id 会合法再次出现，
   * 旧条目仍在 feedPicks 中，会导致 LazyForEach key 冲突。
   */
  private assignFeedKeys(picks: FeedPick[]): void {
    for (let i = 0; i < picks.length; i++) {
      picks[i].key = FeedKeyRule.make(++this.feedSerial);
    }
  }

  private retryFeed(): void {
    Haptics.light();
    this.feedRetryAt = 0;
    this.feedError = false;
    this.feedOffline = false;
    this.feedHasMore = true;
    this.loadFeed(true, 0);
  }

  /**
   * 一轮完整结束后的续流（问题 5）：
   * 换新 seed、重置本轮 feedSeen、从 page1 继续；每页由 SeededOrder 确定性打散，
   * 避免按原顺序重播。只有 feedRoundEnded=true 才允许，未满一轮不会提前重复。
   *
   * 边界说明：兼容源只有一份全库序列，跨轮重复图只会在「上一轮已完整翻完」后出现，
   * 属于预期的循环推荐；界面不会在未满一轮时重复。
   */
  private startNextRound(): void {
    if (this.feedInflight || !this.feedRoundEnded || this.feedOffline) {
      return;
    }
    this.feedRound++;
    this.feedCursor = HomeRecommendApi.nextRoundCursor(this.feedCursor, this.todayKey());
    this.feedSeen = new HomeSeen();
    this.feedHasMore = true;
    this.feedRoundEnded = false;
    this.feedError = false;
    this.refreshFeedExcluded();
    this.loadFeed(true, 0, FeedComposer.LIMIT);
  }

  private footerText(): string {
    if (this.feedError) {
      return '加载失败 · 重试';
    }
    if (!this.feedHasMore && this.feedPicks.length > 0) {
      return '已加载全部';
    }
    return '';
  }

  // ==================== 列表组装 / sections ====================

  private mkItem(kind: string, key: string, w: Wallpaper | undefined, wide: boolean): HomeItem {
    const it = new HomeItem();
    it.kind = kind;
    it.key = key;
    it.wide = wide;
    if (w !== undefined) {
      it.wallpaper = w;
    }
    return it;
  }

  private rebuildItems(): void {
    const its: HomeItem[] = [];
    its.push(this.mkItem('top', 'home_top', undefined, false));
    // 二次元 / 美女真人 / 真人三栏紧跟每日精选往期，位于精选 16 张之前
    // 各栏 0 张时不生成条目：避免 0 高度 FlowItem 影响后续行
    if (this.animeRail.items.length > 0) {
      its.push(this.mkItem('railAnime', 'home_rail_anime', undefined, false));
    }
    if (this.beautyRail.items.length > 0) {
      its.push(this.mkItem('railBeauty', 'home_rail_beauty', undefined, false));
    }
    if (this.recentRail.items.length > 0) {
      its.push(this.mkItem('railRecent', 'home_rail_recent', undefined, false));
    }
    // 精选标题行（含「换一批」），紧贴 2 列精选段
    its.push(this.mkItem('featHead', 'home_feat_head', undefined, false));
    for (let i = 0; i < this.featured.length; i++) {
      const w: Wallpaper = this.featured[i];
      its.push(this.mkItem('featured', `feat_${w.id}`, w, false));
    }
    // 两组分类横滑：精选 16 张之后依次为「宠物 → 风景」（按名称/ slug 排定，不依赖接口顺序）
    const catIdx: number[] = this.orderedRailIndices();
    for (let i = 0; i < catIdx.length; i++) {
      const idx: number = catIdx[i];
      its.push(this.mkItem(`r${idx}`, `home_rail_cat_${idx}`, undefined, false));
    }
    its.push(this.mkItem('sep', 'home_sep', undefined, false));
    for (let i = 0; i < this.feedPicks.length; i++) {
      const p: FeedPick = this.feedPicks[i];
      const w: Wallpaper = p.wallpaper;
      its.push(this.mkItem(p.wide ? 'wide' : 'card', p.key, w, p.wide));
    }
    if (this.feedLoading) {
      // 一个 FlowItem 内并列 3 个灰块（见 skeletonCard），整段占满一行
      its.push(this.mkItem('skeleton', 'home_skeleton', undefined, false));
    }
    const ft: string = this.footerText();
    if (ft.length > 0) {
      const foot = this.mkItem('footer', 'home_footer', undefined, false);
      foot.footerText = ft;
      its.push(foot);
    }
    this.items = its;
    this.ds.updateAll(its);
    this.syncSections(its);
  }

  private crossCountOf(item: HomeItem): number {
    if (item.kind === 'featured' || item.kind === 'card') {
      return 2;
    }
    if (item.kind === 'skeleton') {
      // 骨架整体作为一个全宽段，内部三等分，避免 2 列下末行留第 4 格黑空
      return SkeletonRule.CROSS_COUNT;
    }
    return 1;
  }

  private sectionMargin(kind: string): Margin {
    if (kind === 'top') {
      const m0: Margin = { left: 0, right: 0, top: 0, bottom: 0 };
      return m0;
    }
    if (kind === 'featured' || kind === 'featHead') {
      const m1: Margin = { left: 16, right: 16, top: 0, bottom: 0 };
      return m1;
    }
    if (kind === 'sep') {
      const m2: Margin = { left: 16, right: 16, top: 18, bottom: 0 };
      return m2;
    }
    if (kind === 'railAnime' || kind === 'railBeauty' || kind === 'railRecent') {
      const m4: Margin = { left: 0, right: 0, top: 4, bottom: 0 };
      return m4;
    }
    const m3: Margin = { left: 16, right: 16, top: 10, bottom: 0 };
    return m3;
  }

  /**
   * 把 item 序列切成 section：列数变化（2 列 <-> 1 列）必须断开，
   * 这样满宽卡、顶部区、分隔行各自独占 1 列段，普通卡在 2 列段内瀑布排布。
   */
  private syncSections(items: HomeItem[]): void {
    const secs: SectionOptions[] = [];
    if (items.length > 0) {
      let start: number = 0;
      let cross: number = this.crossCountOf(items[0]);
      for (let i = 1; i <= items.length; i++) {
        const nextCross: number = i < items.length ? this.crossCountOf(items[i]) : -1;
        if (i === items.length || nextCross !== cross) {
          const s: SectionOptions = {
            itemsCount: i - start,
            crossCount: cross,
            margin: this.sectionMargin(items[start].kind),
            rowsGap: 10,
            columnsGap: 8
          };
          secs.push(s);
          start = i;
          cross = nextCross;
        }
      }
    }
    this.flowSections.splice(0, this.flowSections.length(), secs);
  }

  // ==================== 滚动 / 回顶 ====================

  private handleScroll(): void {
    const y: number = this.scroller.currentOffset().yOffset;
    if (y > 1 && !this.userScrolled) {
      this.userScrolled = true;
    }
    if (y > 1200) {
      if (!this.showBackTop) {
        this.showBackTop = true;
      }
      this.scheduleBackTopHide();
    } else if (y < 300) {
      if (this.showBackTop) {
        this.showBackTop = false;
      }
    } else if (this.showBackTop) {
      this.scheduleBackTopHide();
    }
  }

  /** 停手 3s 淡出（每次滚动重新计时） */
  private scheduleBackTopHide(): void {
    if (this.backTopTimer >= 0) {
      clearTimeout(this.backTopTimer);
    }
    this.backTopTimer = setTimeout((): void => {
      this.showBackTop = false;
      this.backTopTimer = -1;
    }, 3000);
  }

  private scrollToTop(): void {
    Haptics.light();
    this.showBackTop = false;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 500, curve: Curve.EaseInOut } });
  }

  private handleScrollIndex(first: number, last: number): void {
    if (!this.userScrolled || this.feedInflight || this.feedOffline) {
      return;
    }
    if (last < this.items.length - 6) {
      return;
    }
    // 本轮已完整翻完：滚到末尾附近时换 seed 续流（不按原序重播）
    if (!this.feedHasMore) {
      if (this.feedRoundEnded) {
        this.startNextRound();
      }
      return;
    }
    if (this.feedPicks.length === 0) {
      return;
    }
    // 距底部约 5 张预取（items 末尾还可能有骨架/提示，用内容末位判断）
    this.loadFeed(false, 0);
  }

  // ==================== 预览池 ====================

  private geoId(w: Wallpaper): string {
    return `wpic_${w.id}`;
  }

  /** 已加载推荐（含精选/日报/两组横滑）拼预览池，左右滑覆盖推荐 */
  private neighborOf(current: Wallpaper, dir: number): Wallpaper | undefined {
    const pool: Wallpaper[] = [];
    const seen = new HomeSeen();
    if (this.daily.wallpaper !== undefined && !seen.has(this.daily.wallpaper)) {
      seen.add(this.daily.wallpaper);
      pool.push(this.daily.wallpaper);
    }
    for (let i = 0; i < this.rails.length; i++) {
      const items: Wallpaper[] = this.rails[i].items;
      for (let k = 0; k < items.length; k++) {
        if (!seen.has(items[k])) {
          seen.add(items[k]);
          pool.push(items[k]);
        }
      }
    }
    for (let i = 0; i < this.featured.length; i++) {
      if (!seen.has(this.featured[i])) {
        seen.add(this.featured[i]);
        pool.push(this.featured[i]);
      }
    }
    for (let i = 0; i < this.feedPicks.length; i++) {
      const w: Wallpaper = this.feedPicks[i].wallpaper;
      if (!seen.has(w)) {
        seen.add(w);
        pool.push(w);
      }
    }
    let idx: number = -1;
    for (let i = 0; i < pool.length; i++) {
      if (pool[i].id === current.id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return undefined;
    }
    const nextIdx: number = idx + dir;
    if (nextIdx < 0 || nextIdx >= pool.length) {
      return undefined;
    }
    return pool[nextIdx];
  }

  private openPreview(w: Wallpaper | undefined): void {
    if (w === undefined) {
      return;
    }
    Haptics.light();
    this.hideTabBar(true);
    this.previewItem = w;
    animateTo({ duration: 320, curve: Curve.EaseOut }, (): void => {
      this.previewVisible = true;
    });
  }

  /** 点击搜索胶囊：切到图库全库搜索入口（空词由图库默认列表承接） */
  private submitSearch(): void {
    Haptics.light();
    this.onSearch('');
  }

  private findLocalWallpaper(id: string): Wallpaper | undefined {
    for (let i = 0; i < LocalWallpapers.ALL.length; i++) {
      if (LocalWallpapers.ALL[i].id === id) {
        return LocalWallpapers.ALL[i];
      }
    }
    return undefined;
  }

  private localOf(w: Wallpaper): Resource | undefined {
    return LocalWallpapers.getThumb(w.id);
  }

  private toggleFavorite(w: Wallpaper, fav: boolean): void {
    // 按目标状态写入（不做盲 toggle），避免爱心回显延迟时连点造成反向操作
    PreferenceUtil.setFavoriteItem(w.id, w, fav);
  }

  // ==================== UI：顶部 ====================

  @Builder
  topArea() {
    Column() {
      // 全宽日报大图 + 浮层（无圆角、左右出血）
      Stack({ alignContent: Alignment.TopStart }) {
        RemoteImage({
          url: this.daily.imageUrl,
          fallback: this.daily.wallpaper !== undefined ? this.localOf(this.daily.wallpaper) : undefined,
          fit: ImageFit.Cover
        })
          .width('100%')
          .height(500)
          .backgroundColor('#14151A')
          .geometryTransition(this.daily.wallpaper !== undefined ? this.geoId(this.daily.wallpaper) : '')
          .onClick((): void => {
            this.openPreview(this.daily.wallpaper);
          })

        // 顶部压暗便于 Logo/胶囊阅读，底部渐变到 62%
        Column()
          .width('100%')
          .height(500)
          .linearGradient({
            angle: 180,
            colors: [['#6B000000', 0], ['#00000000', 0.26], ['#00000000', 0.55], ['#9E000000', 1]]
          })
          .hitTestBehavior(HitTestMode.None)

        // Logo + 搜索胶囊（叠在大图上，不单独占行、不吸顶）
        Row() {
          Text('ZeroOne')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textShadow({ radius: 6, color: '#73000000', offsetX: 0, offsetY: 1 })
          Row({ space: 6 }) {
            Text('🔍').fontSize(13).fontColor('#EDEDF2')
            Text('搜索壁纸 / 合辑')
              .fontSize(12)
              .fontColor('#D5D5DE')
              .maxLines(1)
          }
          .layoutWeight(1)
          .height(38)
          .padding({ left: 14, right: 14 })
          .margin({ left: 12 })
          .backgroundColor('#24FFFFFF')
          .border({ width: 1, color: '#2EFFFFFF' })
          .borderRadius(19)
          .backgroundBlurStyle(BlurStyle.Thin)
          .onClick((): void => {
            this.submitSearch();
          })
        }
        .width('100%')
        .height(38)
        .padding({ left: 16, right: 16 })
        .margin({ top: 32 })

        // 左下：日期（22sp/600）+ 期号（10.5sp，有值才显示）
        Column() {
          Column({ space: 4 }) {
            if (this.daily.dateText.length > 0) {
              Text(this.daily.dateText)
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            if (this.daily.issueNo > 0) {
              Row({ space: 6 }) {
                Column()
                  .width(2)
                  .height(12)
                  .backgroundColor('#F0D08A')
                Text(`第 ${this.daily.issueNo} 期`)
                  .fontSize(10.5)
                  .fontColor('#F0D08A')
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .width('100%')
        .height(500)
        .justifyContent(FlexAlign.End)
        .padding({ left: 18, right: 18, bottom: 18 })
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height(500)

      // 每日精选往期（横向日期列表，最新在最左）
      this.dailyHistoryRow()

      // 精选标题行与两组分类横滑已拆为独立条目（顺序见 rebuildItems）
    }
    .width('100%')
  }

  /** 精选标题行（位于动漫/写真两栏之后、16 张网格之前） */
  @Builder
  featuredHeaderRow() {
    Row() {
      Text('精选')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
      Text('16 张')
        .fontSize(9)
        .fontColor('#A8A8B5')
        .backgroundColor('#24252B')
        .borderRadius(8)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .margin({ left: 6 })
      Blank()
      Text('换一批 ↻')
        .fontSize(10)
        .fontColor('#A8A8B5')
        .padding({ left: 8, right: 2, top: 6, bottom: 6 })
        .onClick((): void => {
          this.changeFeatured();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 8 })
  }

  @Builder
  railRow(index: number) {
    if (index < this.rails.length) {
      this.railBlock(`r${index}`, `r${index}`, true, this.rails[index].slug.indexOf('local_') < 0)
    }
  }

  /**
   * kind → 分区数据。@Builder 的参数按值传递时不会随状态刷新，
   * 因此这里只传稳定的字符串 kind，数据在 builder 内部实时读取。
   */
  private sectionOf(kind: string): AlbumSection {
    if (kind === 'anime') {
      return this.animeRail;
    }
    if (kind === 'beauty') {
      return this.beautyRail;
    }
    if (kind === 'recent') {
      return this.recentRail;
    }
    const idx: number = Number.parseInt(kind.substring(1));
    if (Number.isFinite(idx) && idx >= 0 && idx < this.rails.length) {
      return this.rails[idx];
    }
    return new AlbumSection();
  }

  /** 是否宠物类 rail（名称或 slug 命中动物/宠物） */
  private isPetRail(s: AlbumSection): boolean {
    const n: string = s.name;
    return n.indexOf('宠物') >= 0 || n.indexOf('动物') >= 0
      || s.slug.indexOf('animal') >= 0 || s.slug.indexOf('pet') >= 0;
  }

  /** 分类 rail 展示顺序：宠物优先，其余按原顺序（指定「宠物 → 风景」） */
  private orderedRailIndices(): number[] {
    const out: number[] = [];
    for (let i = 0; i < this.rails.length; i++) {
      if (this.isPetRail(this.rails[i])) {
        out.push(i);
      }
    }
    for (let i = 0; i < this.rails.length; i++) {
      if (!this.isPetRail(this.rails[i])) {
        out.push(i);
      }
    }
    return out;
  }

  /**
   * 通用横滑 rail（标题行 + 横滑卡，样式与顶部两组分类完全一致）。
   *
   * 卡片按原图宽高比渲染，但**高度固定**、宽度随比例换算（横图变宽、竖图变窄），
   * 因此同一行内基线完全对齐、滚动时不会上下跳动（见 railCardWidth）。
   *
   * withSkeleton=true：未加载时显示 3 个灰块（顶部编配合辑沿用旧表现）；
   * withSkeleton=false：未加载或 0 张时整块隐藏 —— 「美女真人」当前无真实
   * 数据（分类/标签/关键词均 0 命中），不能凭空造分类，也不留空标题。
   */
  @Builder
  railBlock(kind: string, keyTag: string, withSkeleton: boolean, showMore: boolean) {
    if ((withSkeleton && !this.sectionOf(kind).loaded) ||
      (this.sectionOf(kind).loaded && this.sectionOf(kind).items.length > 0)) {
      Column() {
        Row() {
          Text(this.sectionOf(kind).name)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#EDEDF2')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (showMore) {
            Text('更多 ›')
              .fontSize(10)
              .fontColor('#9B9CA8')
              .padding({ left: 14, right: 2, top: 8, bottom: 8 })
              .onClick((): void => {
                Haptics.light();
                this.onMore(this.sectionOf(kind).slug);
              })
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 14, bottom: 8 })

        if (this.sectionOf(kind).loaded) {
          List({ space: 8 }) {
            ForEach(this.sectionOf(kind).items, (w: Wallpaper) => {
              ListItem() {
                Stack() {
                  RemoteImage({
                    url: w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl,
                    fallback: this.localOf(w),
                    fit: ImageFit.Cover
                  })
                    .width('100%')
                    .height('100%')
                  CardStatsOverlay({
                    w: w,
                    onFavorite: (item: Wallpaper, fav: boolean): void => {
                      this.toggleFavorite(item, fav);
                    }
                  })
                }
                .width(this.railCardWidth(w))
                .height(RAIL_CARD_H)
                .borderRadius(12)
                .clip(true)
                .backgroundColor('#1A1A1A')
                .onClick((): void => {
                  this.openPreview(w);
                })
              }
            }, (w: Wallpaper) => `rail_${keyTag}_${w.id}`)
          }
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .padding({ left: 12, right: 12 })
          .height(RAIL_CARD_H)
          .width('100%')
        } else {
          Row() {
            Column()
              .width(124)
              .height(RAIL_CARD_H)
              .borderRadius(12)
              .backgroundColor('#1A1A1A')
              .margin({ right: 8 })
            Column()
              .width(124)
              .height(RAIL_CARD_H)
              .borderRadius(12)
              .backgroundColor('#1A1A1A')
              .margin({ right: 8 })
            Column()
              .width(124)
              .height(RAIL_CARD_H)
              .borderRadius(12)
              .backgroundColor('#1A1A1A')
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
          .height(RAIL_CARD_H)
        }
      }
      .width('100%')
      .padding({ bottom: 6 })
    }
  }

  /**
   * 每日精选往期（横向日期列表，最新在最左）。
   *
   * 数据来自 `/albums/daily` 的真实历史（2026-11-07：15 期，带 date/issueNo）。
   * 若线上某天只剩当天一期，列表长度 ≤1 → 整行隐藏，不伪造回溯日期。
   */
  @Builder
  dailyHistoryRow() {
    if (this.dailyHistory.length > 1) {
      Column() {
        Row() {
          Text('每日精选 · 往期')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#EDEDF2')
          Text('左滑看更早')
            .fontSize(9)
            .fontColor('#9B9CA8')
            .margin({ left: 8 })
          Blank()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 8 })

        List({ space: 8 }) {
          ForEach(this.dailyHistory, (d: DailyHistoryItem) => {
            ListItem() {
              Stack({ alignContent: Alignment.BottomStart }) {
                RemoteImage({ url: d.imageUrl, fit: ImageFit.Cover })
                  .width('100%')
                  .height('100%')
                Column()
                  .width('100%')
                  .height(46)
                  .linearGradient({
                    angle: 180,
                    colors: [['#00000000', 0], ['#B3000000', 1]]
                  })
                  .hitTestBehavior(HitTestMode.None)
                Text(d.date.length > 0 ? this.fmtIsoDate(d.date) : `第 ${d.issueNo} 期`)
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .padding({ left: 8, right: 8, bottom: 8 })
              }
              .width(96)
              .height(128)
              .borderRadius(12)
              .clip(true)
              .backgroundColor('#1A1A1A')
              .onClick((): void => {
                this.openPreview(d.wallpaper);
              })
            }
          }, (d: DailyHistoryItem) => `dh_${d.issueNo}_${d.date}`)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 12, right: 12 })
        .height(128)
        .width('100%')
      }
      .width('100%')
      .padding({ bottom: 6 })
    }
  }

  // ==================== UI：精选 / 推荐 ====================

  /**
   * 精选卡：2 列，卡片比例 = 原图比例（横图变矮变宽、竖图变高），Cover 不裁内容。
   *
   * 为什么接受「行高不齐」：2 列栅格里「零裁切」与「两列同高」在数学上不可兼得
   * （同高就必须按其中一张的比例裁另一张）。用户明确要求跟原图比例、避免横图主体
   * 被裁，因此优先零裁切；WaterFlow 本身就是瀑布流，纵向错落与合辑详情页一致，
   * 且精选以竖图为主，同行高度差通常很小。
   */
  @Builder
  featuredCard(w: Wallpaper) {
    Stack() {
      RemoteImage({
        url: w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl,
        fallback: this.localOf(w),
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')
      CardStatsOverlay({
        w: w,
        onFavorite: (item: Wallpaper, fav: boolean): void => {
          this.toggleFavorite(item, fav);
        }
      })
    }
    .width('100%')
    .aspectRatio(cardAspect(w))
    .borderRadius(16)
    .clip(true)
    .backgroundColor('#1A1A1A')
    .geometryTransition(this.geoId(w))
    .onClick((): void => {
      this.openPreview(w);
    })
  }

  @Builder
  feedCard(w: Wallpaper, wide: boolean) {
    Stack() {
      RemoteImage({
        url: w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl,
        fallback: this.localOf(w),
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')
      CardStatsOverlay({
        w: w,
        onFavorite: (item: Wallpaper, fav: boolean): void => {
          this.toggleFavorite(item, fav);
        }
      })
    }
    .width('100%')
    .aspectRatio(wide ? Math.max(1.3, cardAspect(w)) : this.normalAspect(w))
    .borderRadius(16)
    .clip(true)
    .backgroundColor('#1A1A1A')
    .geometryTransition(this.geoId(w))
    .onClick((): void => {
      this.openPreview(w);
    })
  }

  /**
   * 普通卡宽高比：直接沿用原图比例（尺寸缺失按 0.75）。
   * 横图由 FeedComposer 直接跳过、只能以满宽卡出现，因此这里不会再出现
   * 「横图被 3:4 裁切」的情况。
   */
  private normalAspect(w: Wallpaper): number {
    return cardAspect(w);
  }

  /**
   * 横滑卡宽度：高度固定 RAIL_CARD_H，宽度 = 高度 × 原图比例，
   * 这样卡片比例就是原图比例、Cover 不裁内容；横图自然变宽、竖图变窄。
   *
   * 选择「固定高度 + 变宽」而不是「固定宽度 + 变高」的原因：
   *  - 横向 List 的高度要按最高的卡算，各行高度不一会导致矮图上下悬浮、空白；
   *  - 固定高度则所有卡共享同一基线，滚动、换数据时行高恒定，不会跳动；
   *  - 横向滑动方向本就是水平，宽度变化不影响滚动顺畅度。
   * 宽度夹在 [96, 300]：16:9（294）与 9:16（93→96）都完整落在区间内不裁切，
   * 只有极端超宽/超长图会被边界夹住（此时裁切幅度也很小）。
   */
  private railCardWidth(w: Wallpaper): number {
    const px: number = Math.round(RAIL_CARD_H * cardAspect(w));
    return Math.min(RAIL_CARD_MAX_W, Math.max(RAIL_CARD_MIN_W, px));
  }

  @Builder
  recommendHeader() {
    Row() {
      Text('推荐')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
      Text('按最新发布 · 持续更新')
        .fontSize(9)
        .fontColor('#75767F')
        .margin({ left: 8 })
      Blank()
    }
    .width('100%')
    .height(40)
    .padding({ left: 0, right: 0, top: 13 })
    .border({ width: { top: 1 }, color: '#2B2C33' })
  }

  @Builder
  skeletonCard() {
    // 3 个灰块同处一个 FlowItem（全宽段内三列等宽），不出现第 4 格黑空
    Row({ space: 8 }) {
      ForEach([0, 1, 2], (_: number, i: number) => {
        Column()
          .layoutWeight(1)
          .height(176)
          .borderRadius(16)
          .backgroundColor('#1A1A1A')
      }, (_: number, i: number) => `sk_${i}`)
    }
    .width('100%')
    .height(176)
  }

  @Builder
  feedFooter(item: HomeItem) {
    Row() {
      Text(item.footerText)
        .fontSize(10)
        .fontColor(item.footerText.indexOf('重试') >= 0 ? '#C7C8D2' : '#6C6D76')
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      if (item.footerText.indexOf('重试') >= 0) {
        this.retryFeed();
      }
    })
  }

  // ==================== build ====================

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      WaterFlow({ scroller: this.scroller, sections: this.flowSections }) {
        LazyForEach(this.ds, (item: HomeItem) => {
          FlowItem() {
            if (item.kind === 'top') {
              this.topArea()
            } else if (item.kind === 'featHead') {
              this.featuredHeaderRow()
            } else if (item.kind === 'featured') {
              this.featuredCard(item.wallpaper)
            } else if (item.kind === 'railAnime') {
              this.railBlock('anime', 'anime', false, true)
            } else if (item.kind === 'railBeauty') {
              this.railBlock('beauty', 'beauty', false, false)
            } else if (item.kind === 'railRecent') {
              this.railBlock('recent', 'recent', false, false)
            } else if (item.kind === 'r0' || item.kind === 'r1') {
              this.railBlock(item.kind, item.kind, true,
                this.rails[Number.parseInt(item.kind.substring(1))].slug.indexOf('local_') < 0)
            } else if (item.kind === 'sep') {
              this.recommendHeader()
            } else if (item.kind === 'wide') {
              this.feedCard(item.wallpaper, true)
            } else if (item.kind === 'card') {
              this.feedCard(item.wallpaper, false)
            } else if (item.kind === 'skeleton') {
              this.skeletonCard()
            } else if (item.kind === 'footer') {
              this.feedFooter(item)
            }
          }
          .width('100%')
        }, (item: HomeItem) => item.key)
      }
      .columnsGap(8)
      .rowsGap(10)
      .cachedCount(4)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .padding({ bottom: 24 })
      .backgroundColor('#000000')
      .onScroll((offset: number, state: ScrollState): void => {
        this.handleScroll();
      })
      .onScrollIndex((first: number, last: number): void => {
        this.handleScrollIndex(first, last);
      })

      // 回顶（仅首页；>1200 出现，<300 消失，停手 3s 淡出）
      Stack() {
        Text('↑')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor('#4D000000')
      .backgroundBlurStyle(BlurStyle.Thin)
      .alignContent(Alignment.Center)
      .margin({ right: 16, bottom: 24 })
      .opacity(this.showBackTop ? 1 : 0)
      .translate({ x: 0, y: this.showBackTop ? 0 : 8 })
      .animation({ duration: 150, curve: Curve.EaseOut })
      .hitTestBehavior(this.showBackTop ? HitTestMode.Default : HitTestMode.None)
      .onClick((): void => {
        this.scrollToTop();
      })

      // 全屏预览（覆盖在回顶之上）
      if (this.previewVisible) {
        ImagePreview({
          wallpaper: this.previewItem,
          neighbor: (current: Wallpaper, dir: number): Wallpaper | undefined => this.neighborOf(current, dir),
          onClose: (): void => {
            this.hideTabBar(false);
            this.previewVisible = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 日报头数据 */
class DailyHero {
  wallpaper: Wallpaper | undefined = undefined;
  issueNo: number = 0;
  dateText: string = '';
  imageUrl: string = '';
}

/** 统一列表条目（顶部/精选/分隔/推荐卡/骨架/底部提示） */
class HomeItem {
  kind: string = '';
  key: string = '';
  wallpaper: Wallpaper = new Wallpaper();
  wide: boolean = false;
  footerText: string = '';
}

/** WaterFlow 的懒加载数据源 */
class HomeDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private data: HomeItem[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): HomeItem {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  updateAll(items: HomeItem[]): void {
    this.data = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
