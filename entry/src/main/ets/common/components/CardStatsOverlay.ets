import { Wallpaper } from '../../model/Wallpaper';
import { formatCount } from '../home/HomeRules';
import { Haptics } from '../utils/Haptics';

/**
 * CardStatsOverlay —— 壁纸卡片三处信息统一布局（2026-11-07 定稿）
 *
 * 三角分布，互不遮挡，也不遮挡图片主体：
 *  - 左上：浏览数（👁 + 数字，0/缺失不渲染）
 *  - 右上：收藏爱心（实心/空心，点击只收藏，不进预览）
 *  - 右下：保存数（↓ + 数字，0/缺失不渲染）
 *
 * 规则：
 *  - 三处内边距统一 8vp，胶囊底色统一 #70000000；
 *  - 数字格式统一走 formatCount：986 / 1.2K / 12K；
 *  - 爱心触控区 32×32（视觉 32），满足 ≥32vp，且不压缩卡片点击；
 *  - 角标本身 hitTestBehavior(None)，不吃点击事件。
 *
 * 后端有 likeCount 字段但线上真实数据全为 0（2026-11-07 实测 1619 张全 0），
 * 因此爱心只显示图标、不显示数字；待后续有真实点赞后再按同一 formatCount 补数字。
 */
@Component
export struct CardStatsOverlay {
  w: Wallpaper = new Wallpaper();
  /**
   * 收藏状态改为组件自己订阅 AppStorage，而不是由父组件按值传 `favorite: boolean`。
   *
   * 原因：本组件在 5 个页面都是通过 @Builder 以普通（无装饰器）参数创建，
   * 父页面的 `favorites` 变化无法推动它重建，只有整页重建（杀进程重启）才会刷新，
   * 表现为「预览里收藏了，返回首页卡片还是空心」。
   * 订阅 favoriteIds 后，PreferenceUtil 的每次写入（含云端拉回）都会让所有卡片即时刷新。
   */
  @StorageProp('favoriteIds') favoriteIds: string[] = [];
  /** 点击收藏：fav 为期望的目标状态（true=收藏 / false=取消），不做盲 toggle */
  onFavorite: (w: Wallpaper, fav: boolean) => void = () => {};

  private isFavorite(): boolean {
    return this.favoriteIds.includes(this.w.id);
  }

  build() {
    Stack() {
      // 左上：浏览数
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.w.viewCount > 0) {
          Row({ space: 3 }) {
            Text('👁').fontSize(10).fontColor('#FFFFFF')
            Text(formatCount(this.w.viewCount)).fontSize(11).fontColor('#FFFFFF')
          }
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor('#70000000')
          .borderRadius(10)
          .margin(8)
        }
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // 右上：收藏爱心（触控区 32×32）
      Stack({ alignContent: Alignment.TopEnd }) {
        Text(this.isFavorite() ? '♥' : '♡')
          .fontSize(17)
          .fontColor('#FF5A75')
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor('#70000000')
          .borderRadius(16)
          .margin(8)
          .onClick(() => {
            Haptics.light();
            // 显式下发目标状态：避免爱心未及时回显时用户连点导致「实际已取消」
            this.onFavorite(this.w, !this.isFavorite());
          })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 右下：保存数
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.w.downloadCount > 0) {
          Row({ space: 3 }) {
            Text('↓').fontSize(10).fontColor('#FFFFFF')
            Text(formatCount(this.w.downloadCount)).fontSize(11).fontColor('#FFFFFF')
          }
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor('#70000000')
          .borderRadius(10)
          .margin(8)
        }
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
  }
}
