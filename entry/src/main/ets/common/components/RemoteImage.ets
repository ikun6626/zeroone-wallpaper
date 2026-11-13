import { image } from '@kit.ImageKit';
import { ImageCache } from '../net/ImageCache';

/**
 * RemoteImage —— 远程图片组件（三级缓存的唯一 UI 入口）
 *
 * 用法：
 * ```
 * RemoteImage({
 *   url: item.thumbUrl,                       // 远程地址（空串时只显示 fallback）
 *   fallback: LocalWallpapers.getThumb(id),   // 本地兜底图（随包资源，秒开）
 *   fit: ImageFit.Cover
 * })
 * ```
 *
 * 行为：
 *  - fallback 随包资源先渲染（首帧不空白）；
 *  - 布局完成后按**实际显示尺寸**（px）向 ImageCache 要降采样 PixelMap，
 *    卡片不再全尺寸解码（1080×2340 ≈ 10MB → 540×720 ≈ 1.5MB）；
 *  - `fullSize: true` 时按原图解码（全屏预览、编辑等需要原始清晰度的场景）；
 *  - 加载失败保持 fallback，不显示破图；
 *  - LazyForEach 复用实例、url 变化时自动重新加载（@Watch），尺寸档变化也会重载。
 */
@Component
export struct RemoteImage {
  /** 远程图片地址（空串 = 纯本地图） */
  @Prop @Watch('onUrlChange') url: string = '';
  /** 本地兜底资源（可选） */
  fallback: Resource | undefined = undefined;
  /**
   * 填充方式（默认 Cover）
   *
   * 必须用 @Prop：父组件（如 ImagePreview）切换"适应 / 铺满"时传入的 ImageFit 会变，
   * 普通成员属性只在构造时赋值一次、不会触发重新渲染 —— 之前这里没装饰导致
   * "适应"按钮点击无响应（objectFit 永远停在初始值）。
   */
  @Prop fit: ImageFit = ImageFit.Cover;
  /** 兜底图填充方式（默认与 fit 一致；本地缩略图通常也是 Cover） */
  @Prop fallbackFit: ImageFit = ImageFit.Cover;
  /**
   * 是否按原图解码（默认 false：按显示尺寸降采样）。
   * 全屏预览/编辑等需要原始清晰度的场景必须传 true，否则保存/放大后是糊的。
   */
  @Prop fullSize: boolean = false;
  /** 远程图加载完成回调（源像素宽高；调用方据此做比例相关决策，如决定铺满/适应） */
  onInfo: (w: number, h: number) => void = (w: number, h: number): void => {};

  /** 缓存命中的 PixelMap（来自 ImageCache，不 release） */
  @State pm: image.PixelMap | undefined = undefined;
  /** 远程图是否已就位（驱动淡入） */
  @State loaded: boolean = false;
  /** 已加载对应的尺寸档 key（url + 尺寸），防止快速切换时旧结果覆盖新结果 */
  private loadedKey: string = '';
  /** 是否有一次加载在途 */
  private loading: boolean = false;
  /** 布局后的实际显示尺寸（px；0 = 尚未布局） */
  private areaW: number = 0;
  private areaH: number = 0;

  aboutToAppear(): void {
    // 原图模式不依赖布局尺寸，立即加载；卡片模式等 onAreaChange 拿到尺寸再解码
    if (this.fullSize) {
      this.startLoad();
    }
  }

  /** url 变化：重置状态并加载新图 */
  onUrlChange(): void {
    if (this.url === this.loadedUrl()) {
      return;
    }
    this.pm = undefined;
    this.loaded = false;
    this.loadedKey = '';
    this.startLoad();
  }

  /** 当前已加载图对应的 url */
  private loadedUrl(): string {
    const cut: number = this.loadedKey.indexOf('|');
    return cut < 0 ? '' : this.loadedKey.substring(0, cut);
  }

  /** 尺寸档：与 ImageCache 的 bucket 保持一致（向上取 64px 整倍数） */
  private bucketOf(px: number): number {
    return px <= 0 ? 0 : Math.max(64, Math.ceil(px / 64) * 64);
  }

  /** 当前应该加载的 key：url + 尺寸档（原图模式固定 orig） */
  private wantKey(): string {
    if (this.fullSize) {
      return `${this.url}|orig`;
    }
    return `${this.url}|${this.bucketOf(this.areaW)}x${this.bucketOf(this.areaH)}`;
  }

  /** 只由布局回调驱动：记录尺寸并按需（重新）解码 */
  private onArea(area: Area): void {
    const w: number = typeof area.width === 'number' ? vp2px(area.width) : 0;
    const h: number = typeof area.height === 'number' ? vp2px(area.height) : 0;
    if (w <= 0 || h <= 0) {
      return;
    }
    // 尺寸变化不足一档时不重载，避免滚动中反复切图
    if (this.bucketOf(w) === this.bucketOf(this.areaW) && this.bucketOf(h) === this.bucketOf(this.areaH)) {
      return;
    }
    this.areaW = w;
    this.areaH = h;
    this.startLoad();
  }

  private startLoad(): void {
    if (this.url.length === 0) {
      return;
    }
    if (this.loading) {
      return;
    }
    if (!this.fullSize && (this.areaW <= 0 || this.areaH <= 0)) {
      // 等布局：卡片尺寸未知时先只显示 fallback，绝不退回全尺寸解码
      return;
    }
    const key: string = this.wantKey();
    if (key === this.loadedKey && this.pm !== undefined) {
      return;
    }
    this.loading = true;
    const targetUrl: string = this.url;
    const wantW: number = this.fullSize ? 0 : this.bucketOf(this.areaW);
    const wantH: number = this.fullSize ? 0 : this.bucketOf(this.areaH);
    ImageCache.getPixelMap(targetUrl, wantW, wantH).then((result: image.PixelMap): void => {
      // 加载期间 url 已变：丢弃过期结果
      if (targetUrl !== this.url) {
        return;
      }
      this.loadedKey = key;
      this.pm = result;
      const info: image.ImageInfo = result.getImageInfoSync();
      this.onInfo(info.size.width, info.size.height);
      // 淡入：200ms 0 → 1
      animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.loaded = true;
      });
    }).catch((): void => {
      // 失败保持 fallback，静默（调用场景多为列表，toast 会轰炸）
    }).finally((): void => {
      this.loading = false;
      // 等待期间 url / 尺寸档已变 → 追载新的
      if (this.url.length > 0 && this.wantKey() !== this.loadedKey) {
        this.startLoad();
      }
    });
  }

  build() {
    Stack() {
      // 本地兜底层（远程图就位后仍垫底：透明区域/加载失败时有内容）
      if (this.fallback !== undefined) {
        Image(this.fallback)
          .width('100%')
          .height('100%')
          .objectFit(this.fallbackFit)
          .onComplete((event) => {
            // 纯本地图（url 为空）不会走远程链路，这里用本地图源尺寸补一次 onInfo，
            // 否则调用方（如 ImagePreview）永远拿不到尺寸、无法按比例决定铺满/适应。
            if (this.url.length === 0 && event !== undefined && event.width > 0 && event.height > 0) {
              this.onInfo(event.width, event.height);
            }
          })
      }
      // 远程图层（淡入）
      if (this.pm !== undefined) {
        Image(this.pm)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .opacity(this.loaded ? 1 : 0)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.onArea(newValue);
    })
  }
}
