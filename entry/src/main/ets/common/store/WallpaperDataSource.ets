import { Wallpaper } from '../../model/Wallpaper';

/**
 * WallpaperDataSource —— 壁纸列表的懒加载数据源（给 LazyForEach 用）
 *
 * 为什么需要它：
 *   `List`/`Grid` 里用 `ForEach` 会**一次性创建所有子组件** —— 295 条壁纸时
 *   295 张图同时被解码驻留，实测 native heap 涨到 60 MB、PSS 约 164 MB，
 *   低端机翻到后面会明显卡顿。
 *   `LazyForEach` 只创建可见区域（+ 少量预取）的组件，图片解码量随之大幅下降。
 *
 * 用法：
 *   private ds: WallpaperDataSource = new WallpaperDataSource();
 *   ...
 *   LazyForEach(this.ds, (item: Wallpaper) => { ... }, (item: Wallpaper) => item.id)
 *
 * 数据变化时必须调用 `updateAll(新数组)`，否则 LazyForEach 不会刷新
 * （它订阅的是本对象发出的通知，不是页面上的 @State）。
 */
export class WallpaperDataSource implements IDataSource {
  private items: Wallpaper[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Wallpaper {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /**
   * 全量替换并通知刷新
   *
   * 用 onDataReloaded（整表重载）而不是逐条 onDataAdded：
   * 壁纸列表每一页都是"重新算过的完整数组"（含收藏排序、宠物优先重排），
   * 逐条 diff 的收益抵不上复杂度。
   */
  updateAll(list: Wallpaper[]): void {
    this.items = list;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}
