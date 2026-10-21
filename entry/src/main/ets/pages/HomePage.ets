import { Wallpaper } from '../model/Wallpaper';
import { LocalWallpapers } from '../common/constants/LocalWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';
import { RemoteImage } from '../common/components/RemoteImage';
import { Haptics } from '../common/utils/Haptics';
import { AlbumsApi, AlbumPage, AlbumSection, ApiHomeComposition, AlbumBrief } from '../common/net/AlbumsApi';

/**
 * HomePage —— 首页（Cuto 式 · 当日新图 Hero Swiper + 多分区横滚）
 *
 * 重做于 2026-09-30（晚）：对标 Cuto 壁纸 App，从「纵向 List + 单列大卡 + 宠物优先」
 * 改为「Hero 大卡横向 Swiper（右滑看昨天）+ 多个合辑分区横滚」。
 *
 * 2026-09-30（深夜）：首页太贫乏，按 Cuto 多分区结构扩展。删除单条「推荐合辑」横滚，
 * 改为对所有合辑（除 daily）各做一个分区：每个分区 = 标题行（左标题 + 右「更多 >」）
 * + 横滚 8 张壁纸小卡（120×180 铺图圆角，无文字遮罩）。分区独立并发加载，逐个出现。
 *
 * 数据源（云端版，与 Z 盘后台配套）：
 *  - Hero Swiper：`GET /api/v1/albums/daily?page=1&pageSize=14`，拉最近 14 期今日精选
 *    （后台 `daily_featured` 表，每天人工放一张图即新增一期；右滑按日期倒序看历史）
 *  - 多分区：`GET /api/v1/albums` 拿所有合辑（排除 daily），每个合辑再调
 *    `GET /api/v1/albums/:slug?page=1&pageSize=8` 拉前 8 张做横滚
 *
 * 三态：骨架屏（拉取中）/ 错误重试（失败）/ 正常（Hero + 多分区横滚）
 * 离线兜底：接口失败显示黑底 + 重试图标，不依赖 295 条内置图
 */
@Component
export struct HomePage {
  /** 打开/关闭全屏预览时隐藏/显示底部 Tab 栏 */
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /** 点分区「更多 >」：由 Index 处理（切到图库 tab 并打开该合辑详情） */
  onMore: (slug: string) => void = (_: string) => {};
  /** Hero Swiper 数据源（最近 N 期今日精选，按 date desc） */
  @State heroItems: Wallpaper[] = [];
  /** 当前 Hero 索引（右滑递增） */
  @State heroIndex: number = 0;
  /** Hero 拉取中 → 显示骨架屏 */
  @State heroLoading: boolean = true;
  /** Hero 拉取失败 → 显示重试态 */
  @State heroError: boolean = false;
  /** 首页多分区（每个合辑一个横滚区，items 异步填充） */
  @State sections: AlbumSection[] = [];
  /** 已在前面分区出现过的 imageUrl/thumbUrl（跨分区去重，避免同一张图在多个分区重复） */
  private seenUrls: string[] = [];
  /** 本地收藏 ID（订阅 AppStorage 广播，跨 Tab 一致） */
  @StorageProp('favoriteIds') favorites: string[] = [];
  /** 正在预览的壁纸（Hero 点图进入全屏预览） */
  @State previewItem: Wallpaper | undefined = undefined;

  /** 骨架微光位置（-1 = 左侧屏外；aboutToAppear 驱动到 2.2 无限循环） */
  @State shimmerX: number = -1;

  aboutToAppear(): void {
    this.loadHeroes();
    this.loadSections();
    // shimmer 扫光（无限循环；骨架卸载动画自然停止）
    animateTo({ duration: 1250, iterations: -1, curve: Curve.Linear }, (): void => {
      this.shimmerX = 2.2;
    });
  }

  /** 拉取最近 14 期今日精选作为 Hero Swiper 数据源 */
  private loadHeroes(): void {
    this.heroLoading = true;
    this.heroError = false;
    AlbumsApi.fetchAlbumPage('daily', 1, 14).then((p: AlbumPage): void => {
      this.heroLoading = false;
      // P0：首页永不为空 —— 运营未配 daily 或接口返回空时，用本地目录兜底
      this.heroItems = p.items.length > 0 ? p.items : LocalWallpapers.ALL.slice(0, 14);
      this.heroError = false;
    }).catch((): void => {
      this.heroLoading = false;
      // 接口失败不把用户丢进空态：本地 295 张先顶上
      this.heroItems = LocalWallpapers.ALL.slice(0, 14);
      this.heroError = false;
    });
  }

  /**
   * 拉取首页编排里「上首页」的合辑作为分区，再并发填充每区 8 张壁纸。
   *
   * 改走 `/home/composition`（而非 `/albums` 全量）：后端按 `showOnHome` 过滤 +
   * `homeSlot` 排序，后台把某个合辑置为「不上首页」时 App 立即生效（此前 App 全量渲染，
   * 导致 showOnHome=false 的 minimal / photography 仍出现在首页）。
   * daily 合辑交给 Hero Swiper，这里排除。
   */
  private loadSections(): void {
    AlbumsApi.fetchHomeComposition().then((c: ApiHomeComposition | null): void => {
      if (c === null) {
        this.useLocalSections();
        return;
      }
      const list: AlbumSection[] = [];
      for (let i = 0; i < c.albums.length; i++) {
        const a: AlbumBrief = c.albums[i];
        if (a.slug === 'daily') {
          continue;
        }
        const s = new AlbumSection();
        s.slug = a.slug;
        s.name = a.name;
        s.subtitle = a.subtitle;
        s.coverUrl = a.coverUrl;
        s.count = a.count;
        list.push(s);
      }
      if (list.length === 0) {
        this.useLocalSections();
        return;
      }
      this.sections = list;
      // 并发拉每个分区的 8 张壁纸，逐个填充、逐个出现
      for (let i = 0; i < list.length; i++) {
        this.loadSectionItems(list[i].slug);
      }
    }).catch((): void => {
      this.useLocalSections();
    });
  }

  /** P0 兜底：接口失败/为空时，用本地 295 张壁纸拼一个「本地精选」分区 */
  private useLocalSections(): void {
    const s: AlbumSection = new AlbumSection();
    s.slug = 'local';
    s.name = '本地精选';
    s.subtitle = '离线也能看';
    s.count = LocalWallpapers.ALL.length;
    s.items = LocalWallpapers.ALL.slice(0, 8);
    s.loaded = true;
    this.sections = [s];
  }

  /**
   * 拉单个分区的前 N 张壁纸并填充到对应 section（用 slug 匹配，避免索引漂移）
   *
   * 跨分区去重：拉 16 张，过滤掉已在前面分区出现过的 url（按 seenUrls 比对 thumbUrl/imageUrl），
   * 取前 8 张。并发回调"先到先得"——先加载的分区占住 url，后续分区跳过。
   * 这样同一张图不会在多个分区横滚里重复出现（运营把一张图归入多个合辑时 App 端兜底去重）。
   */
  private loadSectionItems(slug: string): void {
    // 与后端约定：长边≥1440 且 短边≥900，过滤掉 350×260 / 498×1080 这类低清图
    AlbumsApi.fetchAlbumPage(slug, 1, 16, '', 1440, 900).then((p: AlbumPage): void => {
      const filtered: Wallpaper[] = [];
      for (let i = 0; i < p.items.length; i++) {
        const w: Wallpaper = p.items[i];
        const url: string = w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl;
        if (this.seenUrls.indexOf(url) === -1) {
          this.seenUrls.push(url);
          filtered.push(w);
          if (filtered.length >= 8) {
            break;
          }
        }
      }
      const next: AlbumSection[] = this.sections.slice();
      for (let i = 0; i < next.length; i++) {
        if (next[i].slug === slug) {
          next[i].items = filtered;
          next[i].loaded = true;
          break;
        }
      }
      this.sections = next;
    }).catch((): void => {
      const next: AlbumSection[] = this.sections.slice();
      for (let i = 0; i < next.length; i++) {
        if (next[i].slug === slug) {
          next[i].loaded = true;
          break;
        }
      }
      this.sections = next;
    });
  }

  /** 收藏/取消收藏 */
  onToggleFavorite(id: string): void {
    PreferenceUtil.toggleFavorite(id);
  }

  /**
   * 格式化日期为「9月30日 星期三」（Cuto 风格 Hero 左下角文字）
   * uploadTime 无效返回空串
   */
  private fmtDate(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    if (Number.isNaN(d.getTime())) {
      return '';
    }
    const weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    return `${d.getMonth() + 1}月${d.getDate()}日 ${weekdays[d.getDay()]}`;
  }

  /** 本地兜底图（daily 项无本地兜底，返回 undefined） */
  private localOf(item: Wallpaper): Resource | undefined {
    return LocalWallpapers.getThumb(item.id);
  }

  /** 共享元素转场 id（与全屏预览逐字一致） */
  private geoId(item: Wallpaper): string {
    return `wpic_${item.id}`;
  }

  /** 点 Hero 卡 / 分区壁纸卡 → 全屏预览 */
  private openHero(w: Wallpaper): void {
    Haptics.light();
    this.hideTabBar(true);
    animateTo({ duration: 320, curve: Curve.EaseOut }, (): void => {
      this.previewItem = w;
    });
  }

  /**
   * 全屏预览左右滑：在「Hero + 各分区」拼出的图片池里取相邻一张。
   * 按 id 去重（分区之间本就有跨区去重，这里再兜一层防 Hero 与分区撞图）。
   */
  private neighborOf(current: Wallpaper, dir: number): Wallpaper | undefined {
    const pool: Wallpaper[] = [];
    const seen: string[] = [];
    for (let i = 0; i < this.heroItems.length; i++) {
      const w: Wallpaper = this.heroItems[i];
      if (seen.indexOf(w.id) === -1) {
        seen.push(w.id);
        pool.push(w);
      }
    }
    for (let s = 0; s < this.sections.length; s++) {
      const items: Wallpaper[] = this.sections[s].items;
      for (let i = 0; i < items.length; i++) {
        const w: Wallpaper = items[i];
        if (seen.indexOf(w.id) === -1) {
          seen.push(w.id);
          pool.push(w);
        }
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
    const next: number = idx + dir;
    if (next < 0 || next >= pool.length) {
      return undefined;
    }
    return pool[next];
  }

  /** 重试 */
  private onRetry(): void {
    this.loadHeroes();
  }

  /** 是否 Hero 首项（= 当日新图，显示 ◎ 靶心） */
  private isHeroFirst(w: Wallpaper): boolean {
    return this.heroItems.length > 0 && this.heroItems[0].id === w.id;
  }

  /** Hero 卡（Swiper 单项：Cover 铺满 + 左上靶心 + 左下日期/副标题） */
  @Builder
  heroCard(w: Wallpaper) {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 壁纸图 Cover 铺满
      RemoteImage({
        url: w.imageUrl,
        fallback: this.localOf(w),
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')

      // 底部渐变遮罩：保证日期/标题可读
      Column()
        .width('100%')
        .height(160)
        .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#CC000000', 1]] })

      // 左上 ◎ 靶心（仅第一张=当日新图显示）
      if (this.isHeroFirst(w)) {
        Text('◎')
          .fontSize(22)
          .fontColor('#FFFFFF')
          .position({ x: 16, y: 16 })
      }

      // 左下日期 + 副标题
      Column({ space: 6 }) {
        Text(this.fmtDate(w.uploadTime))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        if (w.title.length > 0) {
          Text(w.title)
            .fontSize(13)
            .fontColor('#E0E0E0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .borderRadius(20)
    .clip(true)
    .backgroundColor('#1C1D22')
    .geometryTransition(this.geoId(w))
    .onClick(() => {
      this.openHero(w);
    })
  }

  /** 壁纸横滚小卡（120×180 铺图圆角，无文字遮罩，点进全屏预览） */
  @Builder
  wallpaperCard(w: Wallpaper) {
    RemoteImage({
      url: w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl,
      fallback: this.localOf(w),
      fit: ImageFit.Cover
    })
      .width(120)
      .height(180)
      .borderRadius(16)
      .clip(true)
      .backgroundColor('#1A1A1A')
      .geometryTransition(this.geoId(w))
      .onClick(() => {
        this.openHero(w);
      })
  }

  /** 分区行：标题（左标题 + 右「更多 >」）+ 横滚 8 张壁纸小卡 / 骨架占位 */
  @Builder
  sectionRow(s: AlbumSection) {
    Column() {
      // 标题行
      Row() {
        Text(s.name)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('更多 >')
          .fontSize(13)
          .fontColor('#A8A8B5')
          // 扩大触摸热区（文字本身只有十几 px 高，难点）
          .padding({ left: 14, right: 4, top: 8, bottom: 8 })
          .onClick(() => {
            Haptics.light();
            this.onMore(s.slug);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 10 })

      // 横滚内容：已加载且有数据 → 壁纸卡 List；加载中 → 骨架占位；加载完空 → 不显示横滚区
      if (s.loaded && s.items.length > 0) {
        List({ space: 10 }) {
          ForEach(s.items, (w: Wallpaper) => {
            ListItem() {
              this.wallpaperCard(w)
            }
          }, (w: Wallpaper) => w.id)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 16, right: 16, bottom: 8 })
        .height(180)
      } else if (!s.loaded) {
        // 骨架横滚占位（3 张灰块）
        Row() {
          Column()
            .width(120)
            .height(180)
            .borderRadius(16)
            .backgroundColor('#1A1A1A')
            .margin({ right: 10 })
          Column()
            .width(120)
            .height(180)
            .borderRadius(16)
            .backgroundColor('#1A1A1A')
            .margin({ right: 10 })
          Column()
            .width(120)
            .height(180)
            .borderRadius(16)
            .backgroundColor('#1A1A1A')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        .height(180)
      }
    }
    .width('100%')
  }

  /** 骨架屏 Hero（结构与 heroCard 对齐，避免数据到达时布局跳动） */
  @Builder
  skeletonHero() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(20)
        .backgroundColor('#1A1A1A')

      // shimmer 微光带
      Column()
        .width('55%')
        .height('100%')
        .linearGradient({
          angle: 100,
          colors: [['#00FFFFFF', 0], ['#2EFFFFFF', 0.5], ['#00FFFFFF', 1]]
        })
        .offset({ x: `${this.shimmerX * 130}%` })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }

  /** 空态 / 错误态：必须给出可操作出口 */
  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text(this.heroError ? '😿' : '🖼')
        .fontSize(44)
      Text(this.heroError ? '网络开小差了' : '暂时还没有内容')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2F2F5')
      Text(this.heroError ? '点一下重新拉取今日精选' : '稍后再来看看吧')
        .fontSize(12)
        .fontColor('#A8A8B5')
      if (this.heroError) {
        Button('点击重试')
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#C9333D')
          .height(38)
          .width(140)
          .margin({ top: 4 })
          .onClick(() => {
            this.onRetry();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          // ===== 顶部：Logo（无 Plus 胶囊，本期不做会员服务） =====
          Row() {
            Text('ZeroOne')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
          }
          .width('100%')
          .height(44)
          .padding({ left: 16, right: 16 })

          // ===== Hero 区：Swiper / 骨架 / 空态（固定高度，整页可纵向滑动） =====
          if (this.heroItems.length === 0 && this.heroLoading) {
            // 首次拉取：骨架屏
            Column() {
              this.skeletonHero()
            }
            .width('100%')
            .height(460)
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
          } else if (this.heroItems.length === 0) {
            Column() {
              this.emptyState()
            }
            .width('100%')
            .height(460)
          } else {
            // Hero Swiper（右滑看昨天，按 date desc）
            Swiper() {
              ForEach(this.heroItems, (w: Wallpaper) => {
                this.heroCard(w)
              }, (w: Wallpaper) => w.id)
            }
            .index(this.heroIndex)
            .indicator(false)
            .loop(false)
            .duration(320)
            .itemSpace(15)
            .vertical(false)
            .width('100%')
            .height(460)
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
            .onChange((i: number): void => {
              this.heroIndex = i;
            })
          }

          // ===== 多分区横滚（每个合辑一个区，对标 Cuto 动态壁纸/景深/紫色 等分区） =====
          // key 含 loaded + items.length：当分区数据填充后 key 变化，ForEach 才会重新渲染
          // sectionRow 内部的 if(s.loaded) 分支（否则骨架占位永不消失）
          ForEach(this.sections, (s: AlbumSection) => {
            this.sectionRow(s)
          }, (s: AlbumSection) => `${s.slug}_${s.loaded}_${s.items.length}`)

          // 底部留白（避免最后一张卡被 Tab 栏遮住）
          Column()
            .width('100%')
            .height(32)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')

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
  }
}
