import { Wallpaper } from '../model/Wallpaper';
import { DefaultWallpapers } from '../common/constants/DefaultWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { WallpaperStore } from '../common/store/WallpaperStore';
import { ImagePreview } from '../common/components/ImagePreview';

/**
 * HomePage —— 首页（Cuto 式大图卡片流 · 高级黑 · 宠物主题）
 *
 * 特点：
 *  - 大图卡片一张张下滑浏览（约 3:4 大图，留白充足）
 *  - 顶部「今日精选 · 第 N 期」徽标（金 #E6C07E）
 *  - 内容：动物萌宠为主，每 6 张穿插 1 张风景/极简等
 *  - 卡片：图 + 底部信息（标题/标签）+ 心形收藏；点图进入全屏预览（保存/动态/编辑）
 *
 * 三态与容错（状态全部来自 WallpaperStore 的 AppStorage 键）：
 *  - 骨架屏：无缓存且首屏加载中 → 骨架卡片，不再纯黑
 *  - 错误态：首屏失败 → 图标 + 文案 + 「点击重试」
 *  - 分页失败：列表底部给「加载失败，点击重试」，能力不被永久锁死
 *  - 离线兜底：云端不可用 → 顶部提示条 + 重试
 */
@Component
export struct HomePage {
  /** 打开/关闭全屏预览时隐藏/显示底部 Tab 栏 */
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /** 展示中的壁纸（宠物优先排列） */
  @State wallpapers: Wallpaper[] = [];
  /** 本地收藏 ID（订阅 AppStorage 广播，跨 Tab 一致） */
  @StorageProp('favoriteIds') favorites: string[] = [];
  /** 正在预览的壁纸 */
  @State previewItem: Wallpaper | undefined = undefined;
  /** 云端壁纸列表（由 Index 入口统一拉取写入 AppStorage，避免多页面并发同步） */
  @StorageProp('wallpaperList') @Watch('onWallpaperChange') cloudWallpapers: Wallpaper[] = [];
  /** 网络图已加载完成的壁纸 id（加载后释放本地兜底图，节省内存） */
  @State remoteReady: string[] = [];
  // ===== 以下四项来自 WallpaperStore 的状态键（键名必须与 StoreKeys 逐字一致） =====
  /** 首屏加载中：只在"无数据可展示"时为 true → 显示骨架屏而不是黑屏 */
  @StorageProp('wallpaperLoading') loading: boolean = false;
  /** 分页加载中 */
  @StorageProp('wallpaperLoadingMore') loadingMore: boolean = false;
  /** 是否还有下一页（请求失败时保持 true，不会永久锁死） */
  @StorageProp('wallpaperMore') more: boolean = true;
  /** 最近一次请求失败 → 显示"点击重试" */
  @StorageProp('wallpaperError') hasError: boolean = false;
  /** 云端不可用，当前展示内置兜底数据 */
  @StorageProp('wallpaperOffline') offline: boolean = false;
  /** 云端失败的具体原因（WallpaperStore 写入，便于不连调试器也能定位配置问题） */
  @StorageProp('wallpaperErrorText') errorText: string = '';

  /** remoteReady 上限：长列表滚动后远端标记无需无限增长 */
  private static readonly REMOTE_READY_MAX: number = 60;
  /** 期号起点（2023-11-14）：仅作为期号计数基准，不再与"今天"挂钩 */
  private static readonly SERIES_EPOCH_MS: number = 1700000000000;

  aboutToAppear(): void {
    // 期号改为按真实"最新上架时间"推导，见 issueLabel()
    this.applyWallpapers(this.cloudWallpapers);
  }

  /** 云端数据到达或更新时，按宠物优先重排列表 */
  onWallpaperChange(): void {
    this.applyWallpapers(this.cloudWallpapers);
  }

  private applyWallpapers(list: Wallpaper[]): void {
    this.wallpapers = this.buildPetFirstList(list);
  }

  /** 宠物为主，每 6 张穿插 1 张其它分类 */
  private buildPetFirstList(list: Wallpaper[]): Wallpaper[] {
    const pets: Wallpaper[] = [];
    const others: Wallpaper[] = [];
    for (const w of list) {
      if (w.category === '动物萌宠') {
        pets.push(w);
      } else {
        others.push(w);
      }
    }
    const out: Wallpaper[] = [];
    let oi: number = 0;
    for (let i = 0; i < pets.length; i++) {
      out.push(pets[i]);
      if ((i + 1) % 6 === 0 && oi < others.length) {
        out.push(others[oi]);
        oi++;
      }
    }
    for (; oi < others.length; oi++) {
      out.push(others[oi]);
    }
    return out;
  }

  /** 收藏/取消收藏（写入后由 AppStorage 广播回本页与其它页） */
  onToggleFavorite(id: string): void {
    PreferenceUtil.toggleFavorite(id);
  }

  /** 列表中最新的上架时间（0 = 没有有效时间） */
  private latestTs(): number {
    let max: number = 0;
    for (const w of this.wallpapers) {
      if (w.uploadTime > max) {
        max = w.uploadTime;
      }
    }
    return max;
  }

  /**
   * 顶部徽标文案
   *
   * 此前期号用 `Date.now()` 推算（自 2023-11 起的天数）——**每天都会 +1，但内容根本没变**，
   * 用户看到"第 900 期"却永远是那几张图，这是一种"假更新"（审计 L2）。
   * 现在改为按列表里最新一条的 uploadTime 推导：内容不更新，期号就不变。
   */
  private issueLabel(): string {
    const ts: number = this.latestTs();
    if (ts <= 0) {
      return '今日精选';
    }
    const no: number = Math.max(1, Math.floor((ts - HomePage.SERIES_EPOCH_MS) / 86400000) + 1);
    const d: Date = new Date(ts);
    return `第 ${no} 期 · ${d.getMonth() + 1}月${d.getDate()}日更新`;
  }

  /**
   * 上拉到底：交给统一数据源加载下一页
   * 并发/到底/离线判断都在 Store 内完成（状态也是 AppStorage 键，不再是私有字段）
   */
  private onReachEnd(): void {
    if (this.previewItem !== undefined) {
      return;
    }
    WallpaperStore.getInstance().loadMore();
  }

  /** 统一失败重试入口 */
  private onRetry(): void {
    WallpaperStore.getInstance().retry();
  }

  /** 本地兜底图（辅助方法，避免 Builder 内声明变量） */
  private localOf(item: Wallpaper): Resource | undefined {
    return DefaultWallpapers.getLocalImg(item.id);
  }

  /** 标记某张网络图已加载完成（新数组引用触发 @State 刷新，并限制上限） */
  private markRemoteReady(id: string): void {
    if (this.remoteReady.includes(id)) {
      return;
    }
    const next: string[] = this.remoteReady.slice();
    next.push(id);
    // 只保留最近 N 条：这些标记只为"摘除本地兜底图"，无需永久保留
    this.remoteReady = next.length > HomePage.REMOTE_READY_MAX
      ? next.slice(next.length - HomePage.REMOTE_READY_MAX)
      : next;
  }

  /** 大图卡片 */
  @Builder
  bigCard(item: Wallpaper) {
    Column() {
      // 图片区（点图进入全屏预览）
      Stack() {
        // 网络图加载完成前显示本地兜底图，完成后摘除本地 Image 释放内存
        if (this.localOf(item) !== undefined && !this.remoteReady.includes(item.id)) {
          Image(this.localOf(item))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        }
        if (item.imageUrl.length > 0) {
          Image(item.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .onComplete(() => {
              this.markRemoteReady(item.id);
            })
        }
      }
      .width('100%')
      .height(430)
      .clip(true)
      .borderRadius(18)
      .backgroundColor('#1C1D22')
      .onClick(() => {
        this.hideTabBar(true);
        this.previewItem = item;
      })

      // 信息区
      Row() {
        Column({ space: 3 }) {
          Text(`${item.title}`)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2F2F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Text(item.category)
              .fontSize(11)
              .fontColor('#FF6B6B')
            ForEach(item.tagList, (t: string) => {
              Text(`#${t}`)
                .fontSize(11)
                .fontColor('#9A9AA5')
            }, (t: string) => t)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 心形收藏
        Text(this.favorites.includes(item.id) ? '❤️' : '🤍')
          .fontSize(22)
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onToggleFavorite(item.id);
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 4, left: 4, right: 4 })
    }
    .width('100%')
    .padding({ left: 6, right: 6 })
  }

  /** 骨架屏卡片：结构与 bigCard 对齐，避免数据到达时布局跳动 */
  @Builder
  skeletonCard() {
    Column() {
      Column()
        .width('100%')
        .height(430)
        .borderRadius(18)
        .backgroundColor('#16171C')
      Row() {
        Column({ space: 8 }) {
          Column().width(130).height(14).borderRadius(7).backgroundColor('#22232A')
          Column().width(88).height(11).borderRadius(6).backgroundColor('#1E1F25')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Column().width(28).height(28).borderRadius(14).backgroundColor('#22232A')
      }
      .width('100%')
      .padding({ top: 12, bottom: 4, left: 4, right: 4 })
    }
    .width('100%')
    .padding({ left: 6, right: 6 })
  }

  /** 骨架屏列表（3 屏高度，足够撑满首屏） */
  @Builder
  skeletonList() {
    Column({ space: 16 }) {
      this.skeletonCard()
      this.skeletonCard()
      this.skeletonCard()
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 4 })
    .layoutWeight(1)
  }

  /** 空态 / 错误态：必须给出可操作出口，不能让用户对着黑屏猜 */
  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text(this.hasError ? '😿' : '🐾')
        .fontSize(44)
      Text(this.hasError ? '网络开小差了' : '暂时还没有内容')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F2F2F5')
      Text(this.hasError ? '云端数据取不到，点一下重新试试' : '稍后再来看看吧')
        .fontSize(12)
        .fontColor('#7A7A85')
      if (this.hasError) {
        Button('点击重试')
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#FF6B6B')
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
      Column() {
        // ===== 顶部：今日精选 + 期数徽标 =====
        Row() {
          Column({ space: 4 }) {
            Text('今日精选')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
            Text('每天一点可爱 · 宠物主题')
              .fontSize(12)
              .fontColor('#9A9AA5')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.issueLabel())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1410')
            .backgroundColor('#E6C07E')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })

        // ===== 离线提示条（云端不可用时明确告知并给重试，而不是让用户以为 App 坏了） =====
        if (this.offline) {
          Row({ space: 8 }) {
            Text('⚠️ 云端暂时连不上，当前展示内置壁纸')
              .fontSize(11)
              .fontColor('#E6C07E')
              .layoutWeight(1)
            if (this.errorText.length > 0) {
              // 直接显示云服务返回的错误码：权限/区域/Schema 问题一眼可辨
              Text(this.errorText)
                .fontSize(10)
                .fontColor('#8A8A95')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            Text('重试')
              .fontSize(11)
              .fontColor('#FF6B6B')
              .onClick(() => {
                this.onRetry();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#1C1D22')
        }

        // ===== 内容区三态：骨架屏 / 错误重试 / 大图卡片流 =====
        if (this.wallpapers.length === 0 && this.loading) {
          // 首次启动且无缓存：骨架屏（此前这里是纯黑，用户不知道在加载还是坏了）
          this.skeletonList()
        } else if (this.wallpapers.length === 0) {
          this.emptyState()
        } else {
          List({ space: 16 }) {
            ForEach(this.wallpapers, (item: Wallpaper) => {
              ListItem() {
                this.bigCard(item)
              }
            }, (item: Wallpaper) => item.id)

            // 列表底部：加载中 / 加载失败可重试 / 到底提示
            ListItem() {
              Row() {
                if (this.loadingMore) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color('#9A9AA5')
                  Text('加载中…')
                    .fontSize(12)
                    .fontColor('#9A9AA5')
                    .margin({ left: 8 })
                } else if (this.hasError && !this.offline) {
                  // 分页失败的唯一恢复入口（此前失败会永久锁死，只能杀进程）
                  // 离线场景由顶部提示条负责，这里不重复打扰
                  Text('加载失败，点击重试')
                    .fontSize(12)
                    .fontColor('#FF6B6B')
                    .onClick(() => {
                      this.onRetry();
                    })
                } else if (!this.more) {
                  Text('—— 已经到底啦 ——')
                    .fontSize(11)
                    .fontColor('#5A5A65')
                }
              }
              .width('100%')
              .height(56)
              .justifyContent(FlexAlign.Center)
            }
          }
          .listDirection(Axis.Vertical)
          .edgeEffect(EdgeEffect.Spring)
          .padding({ left: 10, right: 10, bottom: 20 })
          .layoutWeight(1)
          .onReachEnd(() => {
            this.onReachEnd();
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0F12')

      // ===== 全屏预览 =====
      if (this.previewItem !== undefined) {
        ImagePreview({
          wallpaper: this.previewItem,
          localImg: DefaultWallpapers.getLocalImg(this.previewItem.id),
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
