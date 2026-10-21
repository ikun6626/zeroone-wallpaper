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
 *  - url 非空时从 ImageCache 取 PixelMap（内存 → 磁盘 → 网络），成功后淡入；
 *  - 加载失败保持 fallback，不显示破图；
 *  - LazyForEach 复用实例、url 变化时自动重新加载（@Watch）。
 *
 * 尺寸由父容器约束（width/height 100%），与原 Image 用法一致。
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
  /** 远程图加载完成回调（源像素宽高；调用方据此做比例相关决策，如决定铺满/适应） */
  onInfo: (w: number, h: number) => void = (w: number, h: number): void => {};

  /** 缓存命中的 PixelMap（来自 ImageCache，不 release） */
  @State pm: image.PixelMap | undefined = undefined;
  /** 远程图是否已就位（驱动淡入） */
  @State loaded: boolean = false;
  /** 实际已加载的 url（防止快速切换 url 时旧结果覆盖新结果） */
  private loadedUrl: string = '';
  /** 是否有一次加载在途 */
  private loading: boolean = false;

  aboutToAppear(): void {
    this.startLoad();
  }

  /** url 变化：重置状态并加载新图 */
  onUrlChange(): void {
    if (this.url === this.loadedUrl) {
      return;
    }
    this.pm = undefined;
    this.loaded = false;
    this.startLoad();
  }

  private startLoad(): void {
    if (this.url.length === 0 || this.loading) {
      return;
    }
    if (this.url === this.loadedUrl) {
      return;
    }
    this.loading = true;
    const target: string = this.url;
    ImageCache.getPixelMap(target).then((result: image.PixelMap): void => {
      // 加载期间 url 已变：丢弃过期结果
      if (target !== this.url) {
        return;
      }
      this.loadedUrl = target;
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
      // await 期间 url 已变 → 追载新 url
      if (this.url !== this.loadedUrl && this.url.length > 0) {
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
  }
}
