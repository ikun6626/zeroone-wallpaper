import { display } from '@kit.ArkUI';

/**
 * CanvasSpec —— 壁纸画布规格（决定"一张壁纸最终长什么样"）
 *
 * 三条约定：
 *  1. **画布尺寸跟随具体设备**：直接取屏幕物理像素（px），不再写死 1080×1920。
 *     这样导出图与屏幕 1:1，用户设成壁纸不会被系统二次裁切。
 *  2. **单位只在边界处换算**：画布与导出用 px，ArkUI 布局用 vp，两者靠 `density()` 连接；
 *     手势位移（vp）进 `ViewMath.withDrag` 时一次性换算，避免 vp/px 混用。
 *  3. **导出有长边上限**：4000×6000 的 RGBA 位图约 96MB，不加护栏必然 OOM。
 *
 * ⚠️ 云服务与屏幕信息在模拟器/预览器上可能拿不到，`fromDevice()` 会回退到默认尺寸而不是抛错。
 */

/** 导出模式 */
export enum OutputMode {
  /** 按画布（= 设备屏幕像素）导出：设为壁纸的默认选项，不会被二次裁切 */
  CANVAS = 'canvas',
  /** 按当前构图的原图像素密度导出（不缩放到画布，保留原始细节） */
  NATIVE = 'native',
  /** 按原图完整比例导出（不裁切，仅保留编辑内容） */
  ORIGINAL = 'original'
}

export class CanvasSpec {
  /** 拿不到屏幕信息时的兜底画布（px） */
  static readonly FALLBACK_WIDTH: number = 1080;
  static readonly FALLBACK_HEIGHT: number = 1920;
  /** 导出长边上限（px） */
  static readonly MAX_LONG_EDGE: number = 4096;

  readonly width: number;
  readonly height: number;

  constructor(width: number, height: number) {
    this.width = width > 0 ? Math.round(width) : CanvasSpec.FALLBACK_WIDTH;
    this.height = height > 0 ? Math.round(height) : CanvasSpec.FALLBACK_HEIGHT;
  }

  /**
   * 目标画布 = 设备屏幕物理像素
   * 拿不到（预览器 / 模拟器 / 接口异常）时回退 1080×1920，绝不抛错阻塞渲染
   */
  static fromDevice(): CanvasSpec {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d !== undefined && d.width > 0 && d.height > 0) {
        return new CanvasSpec(d.width, d.height);
      }
    } catch (e) {
      console.error(`CanvasSpec.fromDevice failed, fallback to ${CanvasSpec.FALLBACK_WIDTH}x${CanvasSpec.FALLBACK_HEIGHT}: ${JSON.stringify(e)}`);
    }
    return new CanvasSpec(CanvasSpec.FALLBACK_WIDTH, CanvasSpec.FALLBACK_HEIGHT);
  }

  /** 屏幕像素密度（vp → px 的换算系数）；拿不到时按 3 处理（主流机型） */
  static density(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d !== undefined && d.densityPixels > 0) {
        return d.densityPixels;
      }
    } catch (e) {
      console.error(`CanvasSpec.density failed, assume 3: ${JSON.stringify(e)}`);
    }
    return 3;
  }

  /** 宽高比（> 1 表示横向） */
  ratio(): number {
    return this.height > 0 ? this.width / this.height : 1;
  }

  /** 是否竖向（壁纸应当只支持竖向） */
  isPortrait(): boolean {
    return this.height >= this.width;
  }
}
