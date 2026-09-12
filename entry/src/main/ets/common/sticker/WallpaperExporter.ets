/**
 * ⚠️ 已废弃 / 无调用方（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：全工程已无任何调用方（grep WallpaperExporter 只命中本文件）。
 * 替代：同思路的离屏合成已统一到 common/editor/ImageComposer.composeToJpeg，
 *       并且新实现额外支持文字层、贴纸层与 WYSIWYG 参数对齐（字重/阴影/旋转）。
 * 注意：本文件文档里"由调用方提供 Canvas 上下文"的用法已被淘汰，
 *       照它接线会绕过当前导出链路；如需图层合成请改 ImageComposer。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */
import { image } from '@kit.ImageKit';
import { PixelScope } from '../utils/PixelScope';

/** 合成导出参数 */
export interface ExportOptions {
  /** 输出画布宽/高（像素） */
  canvasW: number;
  canvasH: number;
  /** 背景图（平铺铺满画布） */
  background: image.PixelMap;
  /** 贴纸（透明背景） */
  sticker: image.PixelMap;
  /** 贴纸中心在画布上的位置（像素） */
  stickerX: number;
  stickerY: number;
  /** 缩放（建议 0.5 ~ 3.0） */
  stickerScale: number;
  /** 旋转角度（度，绕贴纸中心） */
  stickerAngleDeg: number;
  // 阴影
  /** 是否启用阴影 */
  shadowEnabled: boolean;
  /** 0~1 透明度 */
  shadowOpacity: number;
  /** 模糊半径(像素) */
  shadowBlur: number;
  /** X偏移(像素) */
  shadowOffsetX: number;
  /** Y偏移(像素) */
  shadowOffsetY: number;
  // 调色（仅对贴纸生效，不影响背景）
  /** -0.5~0.5, 0=不变 */
  brightness: number;
  /** -0.5~0.5, 0=不变 */
  contrast: number;
  /** -0.5~0.5, 正=暖色, 负=冷色, 0=不变 */
  warmth: number;
}

/**
 * WallpaperExporter —— 多图层高清壁纸合成导出（与 UI 解耦）
 *
 * 说明（基于本机 SDK 实测 API）：
 *  - ArkUI `OffscreenCanvas.transferToImageBitmap()` 返回 ImageBitmap，
 *    @ohos.multimedia.image 无 ImageBitmap→PixelMap 桥接；
 *    官方受支持的像素捕获为 `CanvasRenderingContext2D.getPixelMap(x,y,w,h): PixelMap`。
 *  - 因此本导出器把"合成数学"抽成纯函数 render(ctx, opts)（与 OffscreenCanvas
 *    完全相同的 save/translate/rotate/scale/drawImage/restore 变换语义），
 *    由调用方提供一张目标尺寸的 Canvas 上下文完成绘制；
 *    再用 capture(ctx,w,h) 捕获高清 PixelMap → ImagePacker 存 PNG/JPEG。
 *
 * 用法（在 @Component 内持有一个 Canvas）：
 *   WallpaperExporter.render(this.exportCtx, opts);
 *   const pm = await WallpaperExporter.capture(this.exportCtx, w, h, opts);
 */
export class WallpaperExporter {
  /**
   * 纯合成：背景平铺 + 贴纸按 [中心平移 → 旋转 → 缩放] 叠加。
   * 变换语义与 OffscreenCanvas 相同（save/translate/rotate/scale/drawImage/restore）。
   * @param ctx  画布 2D 上下文（ArkUI 受支持像素捕获的上下文类型）
   * @param o    合成参数
   */
  static render(ctx: CanvasRenderingContext2D, o: ExportOptions): void {
    ctx.save();
    ctx.clearRect(0, 0, o.canvasW, o.canvasH);

    // 1) 背景：拉伸铺满整张画布
    ctx.drawImage(o.background, 0, 0, o.canvasW, o.canvasH);

    // 2) 贴纸：以中心为原点做 平移 → 旋转 → 缩放
    const info = o.sticker.getImageInfoSync();
    const sw: number = info.size.width;
    const sh: number = info.size.height;
    ctx.save();
    // 阴影：仅作用于贴纸层
    if (o.shadowEnabled) {
      ctx.shadowColor = `rgba(0,0,0,${o.shadowOpacity})`;
      ctx.shadowBlur = o.shadowBlur;
      ctx.shadowOffsetX = o.shadowOffsetX;
      ctx.shadowOffsetY = o.shadowOffsetY;
    }
    ctx.translate(o.stickerX, o.stickerY);
    ctx.rotate(o.stickerAngleDeg * Math.PI / 180);
    ctx.scale(o.stickerScale, o.stickerScale);
    // 贴纸左上角在中心点的 (-w/2, -h/2)
    ctx.drawImage(o.sticker, -sw / 2, -sh / 2, sw, sh);
    ctx.restore();
    // 清除阴影，避免后续绘制受影响
    ctx.shadowColor = 'transparent';
    ctx.shadowBlur = 0;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 0;

    ctx.restore();
  }

  /**
   * 像素级调色：对 PixelMap 应用 brightness / contrast / warmth
   *  - brightness: r/g/b += brightness * 255
   *  - contrast:    r/g/b = (c - 128) * (1 + contrast) + 128
   *  - warmth:      r += warmth * 40, b -= warmth * 40
   *  - 所有通道 clamp 到 0~255；alpha 通道不变
   * @param pm          输入 PixelMap（RGBA_8888）
   * @param brightness  -0.5~0.5, 0=不变
   * @param contrast    -0.5~0.5, 0=不变
   * @param warmth      -0.5~0.5, 正=暖色, 负=冷色
   * @returns           新 PixelMap（与输入同尺寸）
   */
  static async applyColorAdjust(pm: image.PixelMap, brightness: number, contrast: number,
    warmth: number): Promise<image.PixelMap> {
    const info = pm.getImageInfoSync();
    const w: number = info.size.width;
    const h: number = info.size.height;
    const buf: ArrayBuffer = new ArrayBuffer(pm.getPixelBytesNumber());
    await pm.readPixelsToBuffer(buf);
    const data: Uint8Array = new Uint8Array(buf);
    const bDelta: number = brightness * 255;
    const cMul: number = 1 + contrast;
    const wR: number = warmth * 40;
    const wB: number = warmth * 40;
    for (let i = 0; i < data.length; i += 4) {
      let r: number = data[i] + bDelta + wR;
      let g: number = data[i + 1] + bDelta;
      let b: number = data[i + 2] + bDelta - wB;
      // contrast
      r = (r - 128) * cMul + 128;
      g = (g - 128) * cMul + 128;
      b = (b - 128) * cMul + 128;
      // clamp 0~255
      data[i] = Math.max(0, Math.min(255, r));
      data[i + 1] = Math.max(0, Math.min(255, g));
      data[i + 2] = Math.max(0, Math.min(255, b));
      // alpha 不变
    }
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    };
    return await image.createPixelMap(buf, opts);
  }

  /**
   * 从已绘制的 Canvas 上下文捕获高清 PixelMap（可选：导出前对结果做调色）
   * @param ctx 画布上下文（必须与绘制用同一个）
   * @param w   捕获宽（像素）
   * @param h   捕获高（像素）
   * @param o   合成参数（若 brightness/contrast/warmth 任一非 0，对结果做调色）
   */
  static async capture(ctx: CanvasRenderingContext2D, w: number, h: number,
    o?: ExportOptions): Promise<image.PixelMap> {
    const pm: image.PixelMap = ctx.getPixelMap(0, 0, w, h);
    if (o && (o.brightness !== 0 || o.contrast !== 0 || o.warmth !== 0)) {
      // 调色会新建一张 PixelMap：中间图必须释放，否则每次导出泄漏一张全尺寸位图。
      // 返回值是调色后的新图，所有权转移给调用方。
      try {
        return await WallpaperExporter.applyColorAdjust(pm, o.brightness, o.contrast, o.warmth);
      } finally {
        PixelScope.safeRelease(pm);
      }
    }
    return pm;
  }

  /**
   * 便捷：合成并导出为可保存字节（PNG/JPEG）
   * @param ctx     画布上下文
   * @param o       合成参数
   * @param format  输出格式 image/jpeg | image/png
   * @param quality 质量 0~100
   */
  static async exportPng(ctx: CanvasRenderingContext2D, o: ExportOptions,
    format: string = 'image/png', quality: number = 100): Promise<ArrayBuffer> {
    WallpaperExporter.render(ctx, o);
    const pm: image.PixelMap = await WallpaperExporter.capture(ctx, o.canvasW, o.canvasH, o);
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const opt: image.PackingOption = { format: format, quality: quality };
      return await packer.packing(pm, opt);
    } finally {
      // 捕获图与打包器都是 Native 资源，必须释放
      PixelScope.safeRelease(pm);
      try {
        packer.release();
      } catch (e) {
        console.error(`release packer failed: ${JSON.stringify(e)}`);
      }
    }
  }
}
