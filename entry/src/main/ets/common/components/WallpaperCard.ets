import { Wallpaper } from '../../model/Wallpaper';

/**
 * WallpaperCard —— 壁纸卡片（通用组件）
 *
 * 首页瀑布流、分类网格、我的收藏网格共用。
 * 特性：
 *  - 本地兜底图（默认壁纸有）秒开显示；网络图加载成功后淡入覆盖（混合图片方案）
 *  - 右上角心形收藏按钮，点击回调 onToggle(id, newFav)
 *  - 圆角 12vp、轻阴影（二次元粉色系风格）
 */
@Component
export struct WallpaperCard {
  /** 壁纸数据（@Prop：父组件列表变化时自动同步） */
  @Prop wallpaper: Wallpaper = new Wallpaper();
  /** 是否已收藏（由父组件根据本地收藏列表计算） */
  @Prop isFav: boolean = false;
  /** 本地兜底图（仅内置默认壁纸有值；云端壁纸传 undefined 用浅粉占位） */
  localImg: Resource | undefined = undefined;
  /** 收藏状态切换回调（父组件负责写本地 Preferences） */
  onToggle: (id: string, newFav: boolean) => void = (id: string, newFav: boolean) => {
  };
  /** 点击图片打开预览回调（父组件负责展示全屏预览） */
  onPreview: (wallpaper: Wallpaper) => void = (wallpaper: Wallpaper) => {
  };
  /** 网络图是否加载完成（完成前显示本地兜底图） */
  @State remoteLoaded: boolean = false;
  /** 网络图是否加载失败（失败则保持本地兜底图） */
  @State remoteFailed: boolean = false;

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // ===== 图片层：本地兜底图 + 网络图 =====
      Stack() {
        // 1) 本地兜底图（秒开、离线可用）
        if (this.localImg !== undefined) {
          Image(this.localImg)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else {
          // 云端壁纸无本地图：先给一个浅粉色占位背景
          Column().width('100%').height('100%').backgroundColor('#FFE9EC')
        }
        // 2) 网络图（加载完成后覆盖本地图）
        if (this.wallpaper.imageUrl.length > 0 && !this.remoteFailed) {
          Image(this.wallpaper.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .opacity(this.remoteLoaded ? 1 : 0)
            .animation({ duration: 300, curve: Curve.EaseOut })
            .onComplete(() => {
              this.remoteLoaded = true;
            })
            .onError(() => {
              this.remoteFailed = true;
            })
        }
      }
      .width('100%')
      .height('100%')

      // ===== 收藏按钮（心形） =====
      Text(this.isFav ? '❤️' : '🤍')
        .fontSize(16)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor(Color.White)
        .borderRadius(15)
        .shadow({ radius: 4, color: '#33000000', offsetX: 0, offsetY: 1 })
        .margin({ right: 6, bottom: 6 })
        .onClick(() => {
          this.onToggle(this.wallpaper.id, !this.isFav);
        })
    }
    .width('100%')
    .height('100%')
    .borderRadius(12)
    .clip(true)
    .backgroundColor(Color.White)
    .shadow({ radius: 6, color: '#1A000000', offsetX: 0, offsetY: 2 })
    .onClick(() => {
      // 点击卡片任意位置（除心形按钮）→ 打开全屏预览；
      // 心形按钮有自己的 onClick，子组件优先响应，不会冲突
      this.onPreview(this.wallpaper);
    })
  }
}
