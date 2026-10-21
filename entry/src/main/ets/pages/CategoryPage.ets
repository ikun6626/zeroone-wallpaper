import { Wallpaper } from '../model/Wallpaper';
import { LocalWallpapers } from '../common/constants/LocalWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';
import { WallpaperDataSource } from '../common/store/WallpaperDataSource';
import { RemoteImage } from '../common/components/RemoteImage';
import { Haptics } from '../common/utils/Haptics';
import { AlbumsApi, AlbumBrief, AlbumPage, ColorBrief } from '../common/net/AlbumsApi';
import { ApiConfig } from '../common/net/ApiConfig';

/**
 * CategoryPage —— 合辑页（Cuto 式：两列封面卡 + 点进去看内容）
 *
 * 数据源（2026-09-30 改造）：
 *  - 合辑**不再写死在代码里**：列表来自 `GET /api/v1/albums`（后台「合辑管理」页可配置，
 *    改合辑名/顺序/规则/封面都不用发版）；
 *  - 点开合辑才按需分页拉 `GET /api/v1/albums/:slug`，滚到底自动加载下一页；
 *  - 合辑详情顶部有一排**颜色 chip**（数据来自 `GET /api/v1/colors`），点一下即按主色筛；
 *  - 接口失败时降级：用内置目录按分类拼出合辑，保证离线也有内容可看。
 *
 * 详情视图：点合辑进入 → 壁纸三列网格（Contain 不裁切、可收藏、点图全屏预览）
 */
@Component
export struct CategoryPage {
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /** 合辑列表（来自后台接口，失败则用内置兜底） */
  @State albums: AlbumBrief[] = [];
  /** 正在加载合辑列表 */
  @State loadingAlbums: boolean = true;
  /** 当前打开的合辑（非空则显示详情覆盖层） */
  @State current: AlbumBrief | undefined = undefined;
  /** 当前合辑已加载的壁纸 */
  @State items: Wallpaper[] = [];
  /** 当前合辑的加载/分页状态 */
  @State loadingItems: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  /** 内网接口失败 → 已降级为内置目录 */
  @State fallback: boolean = false;
  /** 颜色筛选：可选主色清单 + 当前选中（空串=不筛） */
  @State colors: ColorBrief[] = [];
  @State pickedColor: string = '';
  /** 标签筛选：从当前合辑已加载内容里提取，选中后走服务端 ?tag= */
  @State pickedTag: string = '';
  @State tagOptions: string[] = [];
  /** 搜索关键词：合辑列表按名称过滤；详情按已加载壁纸的标题/标签/分类过滤 */
  @State keyword: string = '';
  /** 本地快捷筛选：竖屏 / 高清（基于后台回填的尺寸与朝向） */
  @State onlyPortrait: boolean = false;
  @State onlyHd: boolean = false;
  /** 关键词过滤后的详情条数（0 时显示空结果提示） */
  @State filteredCount: number = 0;
  /**
   * 当前合辑（含颜色筛选）的服务端总数，来自详情接口的 `total` 字段
   * （物化数据集去重 + 按当前筛选条件过滤后的真实张数）。
   * 顶栏右侧计数展示它而不是 items.length —— 分页加载中 items.length
   * 只是"已加载多少"，和实际展出的张数对不上（用户反馈的数量不符问题）。
   */
  @State totalNum: number = 0;

  /**
   * 首页「更多」跳转：可见时主动从 AppStorage 事件总线拉取（值为「序号:slug」）。
   * 不用 @Watch：实测不可见的 TabContent 会被框架冻结，@Prop/@StorageProp 的
   * @Watch 在后台一律不投递；改为本页 onVisibleAreaChange 变为可见时拉取最新值。
   */
  /** 合辑列表尚未加载完时，暂存待打开的 slug，loadAlbums 完成后重试 */
  private waitingSlug: string = '';
  /** 已处理过的请求原文，重复可见回调不二次打开 */
  private lastHandledReq: string = '';

  /**
   * 合辑详情的懒加载数据源
   *
   * 一个合辑最多 300 条，用 ForEach 会一次性建满 —— LazyForEach 只建可见的。
   * items 变化时必须 updateAll()，否则列表不刷新。
   */
  private detailDs: WallpaperDataSource = new WallpaperDataSource();
  /** 当前合辑的页码游标 */
  private page: number = 0;
  /** 本地收藏 ID（订阅 AppStorage 广播，跨 Tab 一致） */
  @StorageProp('favoriteIds') favorites: string[] = [];
  /** 正在预览的壁纸 */
  @State previewItem: Wallpaper | undefined = undefined;
  /** 壁纸列表（由 Index 入口统一发布写入 AppStorage，仅用于接口失败时的兜底分组） */
  @StorageProp('wallpaperList') @Watch('onWallpaperChange') catalogWallpapers: Wallpaper[] = [];

  aboutToAppear(): void {
    this.loadAlbums();
    this.loadColors();
  }

  /** 数据到达或更新时重建兜底合辑 */
  onWallpaperChange(): void {
    if (this.fallback) {
      this.albums = this.localAlbums(this.catalogWallpapers);
    }
  }

  /** 拉取合辑列表；失败 → 内置兜底 */
  private loadAlbums(): void {
    this.loadingAlbums = true;
    AlbumsApi.fetchAlbums().then((list: AlbumBrief[]): void => {
      if (list.length > 0) {
        this.albums = list;
        this.fallback = false;
      } else {
        this.albums = this.localAlbums(this.catalogWallpapers);
        this.fallback = true;
      }
      this.loadingAlbums = false;
      // 首页「更多」可能在列表加载期间到达：列表好了就补打开
      this.tryOpenWaiting();
    }).catch((): void => {
      this.albums = this.localAlbums(this.catalogWallpapers);
      this.fallback = true;
      this.loadingAlbums = false;
      this.tryOpenWaiting();
    });
  }

  /** 拉取主色清单（颜色 chip 的数据；失败就空着，不影响浏览） */
  private loadColors(): void {
    AlbumsApi.fetchColors().then((list: ColorBrief[]): void => {
      this.colors = list;
    }).catch((): void => {
      this.colors = [];
    });
  }

  /**
   * 主色名 → 色块颜色。
   *
   * 色卡名称（「黄绿」「橙黄」）是后端色桶的标准色名，但用户不容易想象，
   * 所以在 chip 里并排画一个色块圆点 —— 名称保持不动（不动后端与生产库
   * 的 dominant_color），只是把「这个颜色到底长什么样」直接摆出来。
   * 色值按色桶 hue 取自统一色板；未知色名兜底为灰。
   */
  private colorDotHex(name: string): string {
    if (name === '红') return '#E5484D';
    if (name === '橙黄') return '#F5A524';
    if (name === '黄绿') return '#A3C627';
    if (name === '绿') return '#46A758';
    if (name === '青') return '#12A594';
    if (name === '蓝') return '#3E63DD';
    if (name === '紫') return '#8E4EC6';
    if (name === '粉') return '#E93D82';
    if (name === '灰') return '#8B8D98';
    return '#8B8D98';
  }

  /**
   * 选中/取消某个颜色（仅合辑详情内可用：颜色 chip 也只在详情页展示）
   * 按主色重新筛当前合辑，走 `?color=` 交给服务端过滤。
   */
  private pickColor(c: string): void {
    const next: string = this.pickedColor === c ? '' : c;
    this.pickedColor = next;
    Haptics.light();

    if (this.current === undefined) {
      // 列表页不再展示颜色 chip；防御：没有上下文时不做任何跳转
      return;
    }

    if (this.fallback) {
      // 兜底模式：直接在内存里按分类 + 颜色 + 标签过滤
      this.refreshLocalItems();
      return;
    }
    this.reloadServerItems();
  }

  /** 选中/取消标签（服务端按 tag 名称过滤；可与颜色叠加） */
  private pickTag(tag: string): void {
    this.pickedTag = this.pickedTag === tag ? '' : tag;
    Haptics.light();
    if (this.current === undefined) {
      return;
    }
    if (this.fallback) {
      this.refreshLocalItems();
      return;
    }
    this.reloadServerItems();
  }

  /** 颜色/标签变化后重新拉第一页（共用入口，避免两套状态清理逻辑） */
  private reloadServerItems(): void {
    this.items = [];
    this.detailDs.updateAll([]);
    this.page = 0;
    this.hasMore = false;
    this.totalNum = 0;
    this.filteredCount = 0;
    this.loadPage(true);
  }

  /** 从已加载壁纸中提取标签选项（去重，最多 16 个） */
  private collectTags(list: Wallpaper[]): void {
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const tags: string[] = list[i].tagList;
      for (let j = 0; j < tags.length; j++) {
        const t: string = tags[j].trim();
        if (t.length > 0 && out.indexOf(t) === -1) {
          out.push(t);
        }
      }
    }
    this.tagOptions = out.slice(0, 16);
  }

  /** 详情关键词过滤：标题 / 标签 / 分类（空关键词恢复全部已加载内容） */
  private applyDetailFilter(): void {
    const k: string = this.keyword.trim().toLowerCase();
    let base: Wallpaper[] = this.items;
    if (this.onlyPortrait) {
      base = base.filter((w: Wallpaper): boolean =>
        w.orientation === 'P' || (w.width > 0 && w.height >= w.width));
    }
    if (this.onlyHd) {
      base = base.filter((w: Wallpaper): boolean =>
        Math.max(w.width, w.height) >= 1440 && Math.min(w.width, w.height) >= 900);
    }
    let out: Wallpaper[] = base;
    if (k.length > 0) {
      out = base.filter((w: Wallpaper): boolean =>
        w.title.toLowerCase().indexOf(k) >= 0 ||
          w.tags.toLowerCase().indexOf(k) >= 0 ||
          w.category.toLowerCase().indexOf(k) >= 0);
    }
    this.filteredCount = out.length;
    this.detailDs.updateAll(out);
  }

  /** 兜底模式：按分类 + 颜色 + 标签过滤本地目录，再套关键词 */
  private refreshLocalItems(): void {
    const cur: AlbumBrief | undefined = this.current;
    if (cur === undefined) {
      return;
    }
    const picked: Wallpaper[] = [];
    for (let i = 0; i < this.catalogWallpapers.length; i++) {
      const w: Wallpaper = this.catalogWallpapers[i];
      if (w.category !== cur.name) {
        continue;
      }
      if (this.pickedColor.length > 0 && w.dominantColor !== this.pickedColor) {
        continue;
      }
      if (this.pickedTag.length > 0 && w.tagList.indexOf(this.pickedTag) === -1) {
        continue;
      }
      picked.push(w);
    }
    this.items = picked;
    this.applyDetailFilter();
  }

  /** 按 slug 精确找合辑（用于首页「更多」跳转） */
  private findAlbumBySlug(slug: string): AlbumBrief | undefined {
    for (let i = 0; i < this.albums.length; i++) {
      if (this.albums[i].slug === slug) {
        return this.albums[i];
      }
    }
    return undefined;
  }

  /**
   * 本页变为可见时（Tab 切到图库）主动拉取首页「更多」请求。
   * 不可见 TabContent 会被框架冻结，@Watch 在后台不投递，所以不用状态监听；
   * onMore 先写 AppStorage 再切 tab，到这里值已落定。
   */
  onPageBecameVisible(): void {
    // 本 Tab 在后台被冻结时 @Watch 不投递：可见时同步一次收藏，
    // 保证收藏心形状态与其它 Tab 的操作一致
    this.favorites = PreferenceUtil.getFavoriteIds();
    const req: string = AppStorage.get<string>(ApiConfig.APP_KEY_OPEN_ALBUM) ?? '';
    if (req.length === 0 || req === this.lastHandledReq) {
      return;
    }
    this.lastHandledReq = req;
    const sep: number = req.indexOf(':');
    // 序号:slug 格式：slug 取第一个冒号之后（slug 本身不含冒号）
    const slug: string = sep === -1 ? req : req.substring(sep + 1);
    if (slug.length === 0) {
      return;
    }
    this.waitingSlug = slug;
    this.tryOpenWaiting();
  }

  /** 打开 waitingSlug 对应的合辑；找不到（列表仍在加载）则等 loadAlbums 回调再试 */
  private tryOpenWaiting(): void {
    if (this.waitingSlug.length === 0) {
      return;
    }
    const target: AlbumBrief | undefined = this.findAlbumBySlug(this.waitingSlug);
    if (target !== undefined) {
      this.waitingSlug = '';
      this.openAlbum(target);
    }
  }

  /**
   * 兜底合辑：按内置目录的分类分组（顺序与后台分类一致）
   * 只在接口不可用时使用，保证"断网也有内容可看"。
   */
  private localAlbums(list: Wallpaper[]): AlbumBrief[] {
    const out: AlbumBrief[] = [];
    const cats: string[] = LocalWallpapers.CATEGORIES;
    for (let i = 0; i < cats.length; i++) {
      const name: string = cats[i];
      if (name === '全部') {
        continue;
      }
      let n: number = 0;
      for (let k = 0; k < list.length; k++) {
        if (list[k].category === name) {
          n++;
        }
      }
      if (n === 0) {
        continue;
      }
      const b = new AlbumBrief();
      b.slug = `local_${i}`;
      b.name = name;
      b.subtitle = `${n} 张精选`;
      b.count = n;
      out.push(b);
    }
    return out;
  }

  /** 打开合辑：拉第一页（同时清掉上一次的颜色筛选） */
  private openAlbum(a: AlbumBrief): void {
    this.current = a;
    this.items = [];
    this.detailDs.updateAll([]);
    this.page = 0;
    this.hasMore = false;
    this.totalNum = 0;
    this.pickedColor = '';
    this.pickedTag = '';
    this.keyword = '';
    this.onlyPortrait = false;
    this.onlyHd = false;
    this.tagOptions = [];
    this.filteredCount = 0;
    if (this.fallback) {
      // 兜底模式：直接从内存里的列表取，不发请求
      const picked: Wallpaper[] = [];
      for (let i = 0; i < this.catalogWallpapers.length; i++) {
        if (this.catalogWallpapers[i].category === a.name) {
          picked.push(this.catalogWallpapers[i]);
        }
      }
      this.items = picked;
      this.collectTags(picked);
      this.applyDetailFilter();
      return;
    }
    this.loadPage(true);
  }

  /** 关闭合辑详情 */
  private closeAlbum(): void {
    this.current = undefined;
    this.items = [];
    this.detailDs.updateAll([]);
    this.page = 0;
    this.hasMore = false;
    this.totalNum = 0;
    this.pickedColor = '';
    this.pickedTag = '';
    this.keyword = '';
    this.onlyPortrait = false;
    this.onlyHd = false;
    this.tagOptions = [];
    this.filteredCount = 0;
  }

  /** 拉一页合辑内容（first=true 表示首屏） */
  private loadPage(first: boolean): void {
    const cur: AlbumBrief | undefined = this.current;
    if (cur === undefined) {
      return;
    }
    if (first) {
      this.loadingItems = true;
    } else {
      if (this.loadingMore || !this.hasMore) {
        return;
      }
      this.loadingMore = true;
    }
    const next: number = this.page + 1;
    AlbumsApi.fetchAlbumPage(cur.slug, next, ApiConfig.PAGE_SIZE, this.pickedColor, 0, 0, this.pickedTag)
      .then((page: AlbumPage): void => {
      // 期间用户可能已经切走：丢弃过期结果
      if (this.current === undefined || this.current.slug !== cur.slug) {
        this.loadingItems = false;
        this.loadingMore = false;
        return;
      }
      this.page = next;
      this.hasMore = page.hasMore;
      // 服务端去重 + 当前筛选后的真实张数（详情页顶部计数用）
      this.totalNum = page.total > 0 ? page.total : this.totalNum;
      const merged: Wallpaper[] = first ? page.items : this.items.concat(page.items);
      this.items = merged;
      // 只在"无筛选"的首屏提取标签选项，避免筛选后选项越来越少
      if (first && this.pickedColor.length === 0 && this.pickedTag.length === 0) {
        this.collectTags(merged);
      }
      this.applyDetailFilter();
      this.loadingItems = false;
      this.loadingMore = false;
    }).catch((): void => {
      this.loadingItems = false;
      this.loadingMore = false;
    });
  }

  /** 滚到接近底部时预取下一页（ArkUI 的 onScrollIndex 只回调 first/last） */
  private onDetailScroll(first: number, last: number): void {
    if (this.fallback || !this.hasMore || this.loadingMore) {
      return;
    }
    if (last >= this.items.length - 4) {
      this.loadPage(false);
    }
  }

  /** 本地兜底图（辅助方法） */
  private localOf(item: Wallpaper): Resource | undefined {
    return LocalWallpapers.getThumb(item.id);
  }

  /** 远程地址（缩略图优先，空串表示纯本地） */
  private remoteUrlOf(item: Wallpaper): string {
    return item.thumbUrl.length > 0 ? item.thumbUrl : item.imageUrl;
  }

  /** 共享元素转场 id（与首页/预览一致） */
  private geoId(item: Wallpaper): string {
    return `wpic_${item.id}`;
  }

  /**
   * 全屏预览左右滑：在「当前合辑已加载列表」里取相邻一张。
   * 翻到已加载列表尽头返回 undefined（预览内提示"已经是最后一张"）。
   */
  private neighborOf(current: Wallpaper, dir: number): Wallpaper | undefined {
    let idx: number = -1;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === current.id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return undefined;
    }
    const next: number = idx + dir;
    if (next < 0 || next >= this.items.length) {
      return undefined;
    }
    return this.items[next];
  }

  onToggleFavorite(id: string, item: Wallpaper): void {
    // 带上 item：收藏快照同步登记（云端图不在目录分页里也能在「最爱收藏」展示）
    PreferenceUtil.toggleFavoriteItem(id, item);
  }

  /**
   * 合辑卡片（Cuto 风格）：Cover 铺满 + 暗色遮罩 + 居中白色分类名
   * 极简扁平化，无阴影、无数量胶囊（张数在详情页标题里显示）
   */
  @Builder
  collectionCard(col: AlbumBrief) {
    Stack({ alignContent: Alignment.Center }) {
      // 封面 Cover 铺满（后台配置的封面优先；没配用内置目录同名分类首图兜底）
      RemoteImage({
        url: col.coverUrl,
        fallback: this.coverFallback(col),
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')

      // 暗色遮罩（保证白名可读）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: [['#00000000', 0.5], ['#CC000000', 1]] })

      // 居中白色分类名
      Text(col.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 6, right: 6 })
    }
    .width('100%')
    .aspectRatio(3 / 4)
    .borderRadius(10)
    .clip(true)
    .backgroundColor('#1C1D22')
    .onClick(() => {
      Haptics.light();
      this.openAlbum(col);
    })
  }

  /** 封面兜底图：内置目录里同名分类的第一张缩略图 */
  private coverFallback(col: AlbumBrief): Resource | undefined {
    const list: Wallpaper[] = this.catalogWallpapers;
    for (let i = 0; i < list.length; i++) {
      if (list[i].category === col.name) {
        return LocalWallpapers.getThumb(list[i].id);
      }
    }
    return undefined;
  }

  /** 顶部返回栏（合辑详情） */
  @Builder
  detailHeader(col: AlbumBrief) {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor('#C9333D')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.closeAlbum();
        })
      Column({ space: 2 }) {
        Text(col.name)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (col.subtitle.length > 0) {
          Text(col.subtitle)
            .fontSize(11)
            .fontColor('#A8A8B5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 口径统一：只保留「共 N 张」，避免「20 张」与「552」并排造成矛盾
      Text(`共 ${this.totalNum > 0 ? this.totalNum : this.items.length} 张`)
        .fontSize(13)
        .fontColor('#A8A8B5')
        .maxLines(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 8, left: 8, right: 12 })
  }

  /**
   * 颜色筛选 chip 行（仅在合辑详情页展示）
   *
   * 数据来自 `GET /api/v1/colors`。点一个 chip 就按该主色筛当前合辑
   * （走 `?color=` 交给服务端过滤，不是本地过滤），再点一次取消。
   * 只显示颜色名、不显示张数：/colors 的 count 是全站口径，
   * 放在单个合辑里会与实际筛出的张数对不上（用户反馈的数量不符问题）。
   */
  @Builder
  colorChips() {
    if (this.colors.length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          Text('全部')
            .fontSize(12)
            .fontColor(this.pickedColor.length === 0 ? Color.White : '#A8A8B5')
            .backgroundColor(this.pickedColor.length === 0 ? '#C9333D' : '#1C1D22')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              if (this.pickedColor.length > 0) {
                this.pickColor(this.pickedColor);
              }
            })
          ForEach(this.colors, (c: ColorBrief) => {
            Row({ space: 6 }) {
              // 色块圆点：让「黄绿 / 橙黄」这类名称一眼可辨
              Column()
                .width(10)
                .height(10)
                .borderRadius(5)
                .backgroundColor(this.colorDotHex(c.color))
              Text(c.color)
                .fontSize(12)
                .fontColor(this.pickedColor === c.color ? Color.White : '#A8A8B5')
            }
            .backgroundColor(this.pickedColor === c.color ? '#C9333D' : '#1C1D22')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              this.pickColor(c.color);
            })
          }, (c: ColorBrief) => c.color)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(38)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 合辑列表按关键词过滤（名称 / 副标题） */
  private visibleAlbums(): AlbumBrief[] {
    const k: string = this.keyword.trim().toLowerCase();
    if (k.length === 0) {
      return this.albums;
    }
    return this.albums.filter((a: AlbumBrief): boolean =>
      a.name.toLowerCase().indexOf(k) >= 0 ||
        a.subtitle.toLowerCase().indexOf(k) >= 0);
  }

  /** 搜索框：列表搜合辑；详情搜已加载壁纸的标题/标签/分类 */
  @Builder
  searchBar() {
    Row({ space: 8 }) {
      TextInput({
        text: this.keyword,
        placeholder: this.current === undefined ? '搜索合辑 / 主题' : '搜索标题 / 标签'
      })
        .layoutWeight(1)
        .height(36)
        .fontSize(13)
        .fontColor('#F2F2F5')
        .placeholderColor('#7A7A85')
        .backgroundColor('#1C1D22')
        .borderRadius(18)
        .padding({ left: 14, right: 14 })
        .onChange((v: string): void => {
          this.keyword = v;
          if (this.current !== undefined) {
            this.applyDetailFilter();
          }
        })
      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(13)
          .fontColor('#A8A8B5')
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .backgroundColor('#1C1D22')
          .borderRadius(14)
          .onClick(() => {
            this.keyword = '';
            if (this.current !== undefined) {
              this.applyDetailFilter();
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  /** 标签筛选 chip 行（仅详情页；标签来自当前合辑已加载内容） */
  @Builder
  tagChips() {
    if (this.tagOptions.length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          Text('全部标签')
            .fontSize(12)
            .fontColor(this.pickedTag.length === 0 ? Color.White : '#A8A8B5')
            .backgroundColor(this.pickedTag.length === 0 ? '#C9333D' : '#1C1D22')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .onClick(() => {
              if (this.pickedTag.length > 0) {
                this.pickTag(this.pickedTag);
              }
            })
          ForEach(this.tagOptions, (t: string) => {
            Text(`#${t}`)
              .fontSize(12)
              .fontColor(this.pickedTag === t ? Color.White : '#A8A8B5')
              .backgroundColor(this.pickedTag === t ? '#C9333D' : '#1C1D22')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .onClick(() => {
                this.pickTag(t);
              })
          }, (t: string) => t)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(34)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  /** 本地快捷筛选：竖屏 / 高清（基于后台回填的尺寸与朝向） */
  @Builder
  quickFilters() {
    if (!this.fallback) {
      Row({ space: 8 }) {
      Text('竖屏')
        .fontSize(12)
        .fontColor(this.onlyPortrait ? Color.White : '#A8A8B5')
        .backgroundColor(this.onlyPortrait ? '#C9333D' : '#1C1D22')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .onClick(() => {
          this.onlyPortrait = !this.onlyPortrait;
          Haptics.light();
          this.applyDetailFilter();
        })
      Text('高清')
        .fontSize(12)
        .fontColor(this.onlyHd ? Color.White : '#A8A8B5')
        .backgroundColor(this.onlyHd ? '#C9333D' : '#1C1D22')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        .onClick(() => {
          this.onlyHd = !this.onlyHd;
          Haptics.light();
          this.applyDetailFilter();
        })
      Text('高清 = 长边≥1440 且 短边≥900')
        .fontSize(9)
        .fontColor('#6F6F7A')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2, bottom: 6 })
    }
  }

  /** 合辑详情网格卡片：等比（Contain）完整展示，不裁切 */
  @Builder
  gridCard(item: Wallpaper) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 完整图（深色底，云端优先，随包兜底；Contain 不裁切）
      RemoteImage({
        url: this.remoteUrlOf(item),
        fallback: this.localOf(item),
        fit: ImageFit.Contain,
        fallbackFit: ImageFit.Contain
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#1C1D22')

      // 收藏心形
      Text(this.favorites.includes(item.id) ? '❤️' : '🤍')
        .fontSize(16)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor('#66000000')
        .borderRadius(15)
        .margin({ right: 6, bottom: 6 })
        .onClick(() => {
          Haptics.light();
          this.onToggleFavorite(item.id, item);
        })
    }
    .width('100%')
    .aspectRatio(3 / 4)
    .borderRadius(12)
    .clip(true)
    .backgroundColor('#1C1D22')
    .geometryTransition(this.geoId(item))
    .onClick(() => {
      Haptics.light();
      this.hideTabBar(true);
      animateTo({ duration: 320, curve: Curve.EaseOut }, (): void => {
        this.previewItem = item;
      });
    })
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题（「合辑」改名「图库」，对标 Cuto）=====
        Row() {
          Column({ space: 4 }) {
            Text('图库')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
            Text(this.fallback ? '离线内容 · 按分类浏览' : '按主题挑选 · 后台持续更新')
              .fontSize(12)
              .fontColor('#A8A8B5')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })

        // 搜索合辑名称 / 主题
        this.searchBar()

        // ===== 合辑卡片墙（两列） =====
        // （颜色筛选只放在合辑详情页：列表页没有"当前合辑"语境，
        //   点颜色会被误跳到某个合辑 —— 2026-10-01 用户反馈已移除）
        if (this.loadingAlbums && this.albums.length === 0) {
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36).color('#C9333D')
            Text('正在加载合辑…')
              .fontSize(12)
              .fontColor('#A8A8B5')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.visibleAlbums().length === 0) {
          Column({ space: 12 }) {
            Text('📭').fontSize(44)
            Text(this.albums.length === 0 ? '还没有合辑' : '没有匹配的合辑')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2F2F5')
            Text(this.albums.length === 0 ? '下拉或稍后再来看看' : '换个关键词试试')
              .fontSize(12)
              .fontColor('#A8A8B5')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.visibleAlbums(), (col: AlbumBrief) => {
              GridItem() {
                this.collectionCard(col)
              }
            }, (col: AlbumBrief) => col.slug)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(10)
          .padding({ left: 8, right: 8, bottom: 20 })
          .layoutWeight(1)
          .edgeEffect(EdgeEffect.Spring)
          .enableScrollInteraction(true)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0F12')

      // ===== 合辑详情（覆盖） =====
      if (this.current !== undefined) {
        Column() {
          this.detailHeader(this.current)
          // 搜索当前合辑已加载的壁纸
          this.searchBar()
          // 颜色筛选（数据来自 /api/v1/colors；点选后按主色筛当前合辑）
          this.colorChips()
          // 标签筛选（后端按 tag 名称过滤）
          this.tagChips()
          // 本地快捷筛选：竖屏 / 高清
          this.quickFilters()
          if (this.loadingItems && this.items.length === 0) {
            Column({ space: 10 }) {
              LoadingProgress().width(32).height(32).color('#C9333D')
              Text('正在加载…').fontSize(12).fontColor('#A8A8B5')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (this.filteredCount === 0) {
            Column() {
              Text('💤')
                .fontSize(40)
              Text(this.keyword.trim().length > 0 ? '没有匹配的壁纸'
                : (this.pickedTag.length > 0 || this.pickedColor.length > 0
                  ? '当前筛选下没有壁纸' : '这个合辑暂时没有壁纸'))
                .fontSize(13)
                .fontColor('#A8A8B5')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Grid() {
              LazyForEach(this.detailDs, (item: Wallpaper) => {
                GridItem() {
                  this.gridCard(item)
                }
                .width('100%')
              }, (item: Wallpaper) => item.id)

              // 底部分页提示（占满一行）
              GridItem() {
                Row() {
                  if (this.loadingMore) {
                    LoadingProgress().width(18).height(18).color('#A8A8B5')
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor('#A8A8B5')
                      .margin({ left: 8 })
                  } else if (!this.hasMore && !this.fallback) {
                    Text('—— 已经到底啦 ——')
                      .fontSize(11)
                      .fontColor('#A8A8B5')
                  }
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              }
              .columnStart(0)
              .columnEnd(2)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 12, right: 12, bottom: 16 })
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)
            .enableScrollInteraction(true)
            .onScrollIndex((first: number, last: number): void => {
              this.onDetailScroll(first, last);
            })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0F0F12')
      }

      // ===== 全屏预览 =====
      if (this.previewItem !== undefined) {
        ImagePreview({
          wallpaper: this.previewItem,
          neighbor: (current: Wallpaper, dir: number): Wallpaper | undefined => this.neighborOf(current, dir),
          onClose: () => {
            this.hideTabBar(false);
            this.previewItem = undefined;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .onVisibleAreaChange([0.0], (isVisible: boolean, ratio: number): void => {
      // 图库 tab 变为可见 → 拉取首页「更多」请求（后台冻结期 @Watch 不投递）
      if (isVisible) {
        this.onPageBecameVisible();
      }
    })
  }
}
