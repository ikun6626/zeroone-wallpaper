import { image } from '@kit.ImageKit';

/** 延迟释放等待时长（ms）：约 20 帧，足够 ArkUI 用新图完成一次重绘 */
const DEFER_MS: number = 300;

/**
 * PixelScope —— PixelMap 生命周期作用域（统一资源释放机制）
 *
 * 背景（交互审计 H4）：
 *  PixelMap / ImagePacker 都是 Native 资源，**GC 不会回收，必须显式 release()**。
 *  此前全工程 6 个文件创建 PixelMap、只有 2 个文件释放，且编辑器每次旋转/裁剪/滤镜
 *  都会替换 curPixelMap 却不释放旧的——一张 1080×1920 的 RGBA 位图约 8MB，
 *  进出编辑器几轮就能把低端机压到 OOM/被系统杀。
 *
 * 两类用法：
 *  1. **会持续展示的资源**（如编辑器的 curPixelMap、Image 组件的图源）：
 *     用 setCurrent() 替换。旧图不立即释放，而是延迟 DEFER_MS 再释放——
 *     因为 ArkUI 可能还没用新图重绘完，立刻释放正在被绘制的句柄有绘制异常风险。
 *  2. **一次性中间资源**（如截图、中间调色结果）：
 *     用静态的 safeRelease()，放在 try/finally 里及时释放。
 *
 * 页面/组件销毁时调用 dispose()，把当前持有与待释放的全部清掉。
 *
 * 所有权约定：返回 `Promise<image.PixelMap>` 的工具方法（如 ImageComposer.composeToPixelMap、
 * FilterTask 的并发滤镜等）都是**把所有权转移给调用方**，调用方负责 release。
 */
export class PixelScope {
  /** 当前持有并正在展示的资源 */
  private current: image.PixelMap | undefined = undefined;
  /** 已被替换、等待延迟释放的资源 */
  private pending: image.PixelMap[] = [];
  /** 延迟释放定时器句柄（-1 表示未排程） */
  private timer: number = -1;

  /**
   * 安全释放：undefined / 重复释放 / 已释放都不抛错。
   * 一次性资源统一走这里，避免每处再写一遍 try/catch。
   */
  static safeRelease(pm: image.PixelMap | undefined): void {
    if (pm === undefined) {
      return;
    }
    try {
      pm.release();
    } catch (e) {
      // 已释放或句柄无效：忽略，不打断主流程
      console.error(`PixelScope release failed: ${JSON.stringify(e)}`);
    }
  }

  /** 设置"当前展示"资源：自动把上一张放入延迟释放队列并返回新资源 */
  setCurrent(pm: image.PixelMap): image.PixelMap {
    const old: image.PixelMap | undefined = this.current;
    this.current = pm;
    if (old !== undefined && old !== pm) {
      this.pending.push(old);
      this.scheduleFlush();
    }
    return pm;
  }

  /** 当前是否已持有资源（调试/断言用） */
  hasCurrent(): boolean {
    return this.current !== undefined;
  }

  /** 组件销毁：立即释放全部持有资源（此时不会再渲染，无需延迟） */
  dispose(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    PixelScope.safeRelease(this.current);
    this.current = undefined;
    const list: image.PixelMap[] = this.pending;
    this.pending = [];
    for (const pm of list) {
      PixelScope.safeRelease(pm);
    }
  }

  /** 排程一次延迟释放（已有排程则不重复） */
  private scheduleFlush(): void {
    if (this.timer !== -1) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flushPending();
    }, DEFER_MS);
  }

  /** 释放所有等待中的旧资源 */
  private flushPending(): void {
    const list: image.PixelMap[] = this.pending;
    this.pending = [];
    for (const pm of list) {
      PixelScope.safeRelease(pm);
    }
  }
}
