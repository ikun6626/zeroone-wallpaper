import { Wallpaper } from '../model/Wallpaper';
import { DefaultWallpapers } from '../common/constants/DefaultWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';

/** 合辑 */
interface CollectionInfo {
  key: string;
  title: string;
  sub: string;
  items: Wallpaper[];
}

/**
 * CategoryPage —— 合辑页（高级黑 · 宠物合辑置顶）
 *
 * 主视图：合辑卡片墙（两列大封面卡）
 *  猫咪 / 狗狗 / 动物萌宠 / 自然风光 / 城市建筑 / 极简风格 / 二次元插画
 * 详情视图：点合辑进入 → 该合辑壁纸三列网格（可点心移除收藏、点图全屏预览）
 */
@Component
export struct CategoryPage {
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /** 合辑列表 */
  @State collections: CollectionInfo[] = [];
  /** 当前打开的合辑（非空则显示详情） */
  @State current: CollectionInfo | undefined = undefined;
  /** 本地收藏 ID（订阅 AppStorage 广播，跨 Tab 一致） */
  @StorageProp('favoriteIds') favorites: string[] = [];
  /** 正在预览的壁纸 */
  @State previewItem: Wallpaper | undefined = undefined;
  /** 云端壁纸列表（由 Index 入口统一拉取写入 AppStorage） */
  @StorageProp('wallpaperList') @Watch('onWallpaperChange') cloudWallpapers: Wallpaper[] = [];
  /** 网络图已加载完成的壁纸 id（加载后释放本地兜底图，节省内存） */
  @State remoteReady: string[] = [];

  aboutToAppear(): void {
    this.applyWallpapers(this.cloudWallpapers);
  }

  /** 云端数据到达或更新时重建合辑 */
  onWallpaperChange(): void {
    this.applyWallpapers(this.cloudWallpapers);
  }

  private applyWallpapers(list: Wallpaper[]): void {
    this.collections = this.buildCollections(list);
  }

  /** 组集合：宠物合辑优先，其余按分类 */
  private buildCollections(list: Wallpaper[]): CollectionInfo[] {
    const pick = (pred: (w: Wallpaper) => boolean): Wallpaper[] => {
      const r: Wallpaper[] = [];
      for (const w of list) {
        if (pred(w)) {
          r.push(w);
        }
      }
      return r;
    };
    const cats: Wallpaper[] = pick((w: Wallpaper) => w.id.startsWith('my_cat_'));
    const dogs: Wallpaper[] = pick((w: Wallpaper) => w.id.startsWith('my_dog_'));
    const pets: Wallpaper[] = pick((w: Wallpaper) =>
      w.category === '动物萌宠' && !w.id.startsWith('my_cat_') && !w.id.startsWith('my_dog_'));
    const out: CollectionInfo[] = [];
    if (cats.length > 0) {
      out.push({ key: 'cat', title: '🐈 猫咪合辑', sub: '软萌猫星人', items: cats });
    }
    if (dogs.length > 0) {
      out.push({ key: 'dog', title: '🐕 狗狗合辑', sub: '治愈汪星人', items: dogs });
    }
    if (pets.length > 0) {
      out.push({ key: 'pet', title: '🐾 动物萌宠', sub: '毛茸茸治愈力', items: pets });
    }
    for (const catName of ['自然风光', '城市建筑', '极简风格', '二次元插画']) {
      const items: Wallpaper[] = pick((w: Wallpaper) => w.category === catName);
      if (items.length > 0) {
        const emojiMap: string[] = ['🌄 自然风光', '🏙 城市建筑', '◻️ 极简风格', '🎨 二次元插画'];
        const title: string = emojiMap[['自然风光', '城市建筑', '极简风格', '二次元插画'].indexOf(catName)];
        out.push({ key: catName, title: title, sub: `${items.length} 张精选`, items: items });
      }
    }
    return out;
  }

  /** 封面图 */
  private coverOf(col: CollectionInfo): Wallpaper {
    return col.items[0];
  }

  /** 本地兜底图（辅助方法） */
  private localOf(item: Wallpaper): Resource | undefined {
    return DefaultWallpapers.getLocalImg(item.id);
  }

  /** 标记某张网络图已加载完成（新数组引用触发 @State 刷新） */
  private markRemoteReady(id: string): void {
    if (!this.remoteReady.includes(id)) {
      const next: string[] = this.remoteReady.slice();
      next.push(id);
      this.remoteReady = next;
    }
  }

  onToggleFavorite(id: string): void {
    PreferenceUtil.toggleFavorite(id);
  }

  /**
   * 合辑卡片（Cuto 风格）：封面图完整展示，不被文字遮挡；
   * 标题/说明放在图片下方深色区，右上仅保留一个数量小胶囊
   */
  @Builder
  collectionCard(col: CollectionInfo) {
    Column() {
      Stack() {
        // 网络图加载完成前显示本地兜底图，完成后摘除本地 Image 释放内存
        if (this.coverOf(col) !== undefined && this.localOf(this.coverOf(col)) !== undefined
          && !this.remoteReady.includes(this.coverOf(col).id)) {
          Image(this.localOf(this.coverOf(col)))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        }
        if (this.coverOf(col).imageUrl.length > 0) {
          Image(this.coverOf(col).imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .onComplete(() => {
              this.markRemoteReady(this.coverOf(col).id);
            })
        }
        // 右上角数量胶囊（毛玻璃风格，不遮挡主体）
        Text(`${col.items.length} 张`)
          .fontSize(10)
          .fontColor(Color.White)
          .backgroundColor('rgba(0,0,0,0.45)')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .position({ x: '100%', y: 8 })
          .markAnchor({ x: '100%', y: 0 })
          .margin({ right: 8 })
      }
      .width('100%')
      .aspectRatio(3 / 4)
      .clip(true)
      .borderRadius(16)
      .backgroundColor('#1C1D22')

      // 图片下方：标题 + 说明（文字不再压图，避免图片被“切成两半”）
      Column({ space: 2 }) {
        Text(col.title)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(col.sub)
          .fontSize(11)
          .fontColor('#7A7A85')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 4, right: 4, top: 8, bottom: 2 })
    }
    .width('100%')
    .onClick(() => {
      this.current = col;
    })
  }

  /** 顶部返回栏（合辑详情） */
  @Builder
  detailHeader(col: CollectionInfo) {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor('#FF6B6B')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.current = undefined;
        })
      Text(col.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text(`${col.items.length}`)
        .fontSize(13)
        .fontColor('#9A9AA5')
        .width(40)
    }
    .width('100%')
    .padding({ top: 10, bottom: 8, left: 8, right: 8 })
  }

  /** 合辑详情网格卡片：等比（Contain）完整展示，不裁切 */
  @Builder
  gridCard(item: Wallpaper) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 等比完整图（深色底，多余留黑边）
      Stack() {
        if (this.localOf(item) !== undefined && !this.remoteReady.includes(item.id)) {
          Image(this.localOf(item))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
        if (item.imageUrl.length > 0) {
          Image(item.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .onComplete(() => {
              this.markRemoteReady(item.id);
            })
        }
      }
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
          this.onToggleFavorite(item.id);
        })
    }
    .width('100%')
    .aspectRatio(3 / 4)
    .borderRadius(12)
    .clip(true)
    .backgroundColor('#1C1D22')
    .onClick(() => {
      this.hideTabBar(true);
      this.previewItem = item;
    })
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题 =====
        Row() {
          Column({ space: 4 }) {
            Text('合辑')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
            Text('按主题挑选 · 宠物优先')
              .fontSize(12)
              .fontColor('#9A9AA5')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('🐾')
            .fontSize(20)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })

        // ===== 合辑卡片墙（两列） =====
        Grid() {
          ForEach(this.collections, (col: CollectionInfo) => {
            GridItem() {
              this.collectionCard(col)
            }
          }, (col: CollectionInfo) => col.key)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(14)
        .padding({ left: 12, right: 12, bottom: 20 })
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0F12')

      // ===== 合辑详情（覆盖） =====
      if (this.current !== undefined) {
        Column() {
          this.detailHeader(this.current)
          if (this.current.items.length === 0) {
            Column() {
              Text('💤')
                .fontSize(40)
              Text('这个合辑暂时没有壁纸')
                .fontSize(13)
                .fontColor('#9A9AA5')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Grid() {
              ForEach(this.current.items, (item: Wallpaper) => {
                GridItem() {
                  this.gridCard(item)
                }
                .width('100%')
              }, (item: Wallpaper) => item.id)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 12, right: 12, bottom: 16 })
            .layoutWeight(1)
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
