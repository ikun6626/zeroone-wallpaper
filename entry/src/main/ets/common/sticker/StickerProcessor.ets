/**
 * ⚠️ 已废弃 / 无调用方（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：全工程已无任何调用方（grep generateSticker 只命中本文件）。
 * 原因：贴纸工作台已改为"选背景 + 贴纸自由摆放 + 快照合成"，
 *       原来的遮罩抠图路径（魔法棒涂抹）不再是主流程。
 * 若要恢复"智能抠图"，本类算法仍可用，但注意：返回的 PixelMap 由调用方负责 release
 * （PixelMap 是 Native 资源，GC 不回收，见 common/utils/PixelScope.ets）。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */
import { image } from '@kit.ImageKit';

/**
 * StickerProcessor —— 图像分割 → 透明贴纸生成（纯像素级，无 UI 依赖）
 *
 * 输入：
 *  - sourceImage：宠物原图 PixelMap
 *  - maskImage：分割遮罩 PixelMap（前景不透明/255，背景透明/0；
 *    若遮罩为灰度/白底黑底，则按亮度作为透明度）
 *
 * 逻辑：
 *  1. 分别读取原图与遮罩的 RGBA 像素缓冲
 *  2. 若尺寸不一致，按「最近邻」把遮罩采样到原图坐标（通常遮罩=原图同尺寸，走直通）
 *  3. 逐像素：颜色保留 source 的 RGB；Alpha = 遮罩的 Alpha（若遮罩整幅不透明，
 *     则退化为亮度灰阶作为 Alpha）
 *  4. 输出一张透明背景的贴纸 PixelMap（可被 image packer 打成 PNG 或直接绘制合成）
 *
 * 所有权约定：返回的 PixelMap 由**调用方**负责 release；
 * 入参 sourceImage / maskImage 的所有权仍属于调用方，本类不释放。
 */
export class StickerProcessor {
  /** 遮罩判定的最小不透明度（小于则视为背景） */
  static readonly MASK_ALPHA_TOLERANCE: number = 10;

  /**
   * 生成透明贴纸
   * @param sourceImage 宠物原图
   * @param maskImage   前景/背景遮罩（可不同尺寸，自动最近邻映射）
   * @returns 透明背景贴纸 PixelMap（尺寸 = 原图尺寸）
   */
  static async generateSticker(sourceImage: image.PixelMap, maskImage: image.PixelMap): Promise<image.PixelMap> {
    // 1) 读取原图信息与像素
    const sInfo = sourceImage.getImageInfoSync();
    const sw: number = sInfo.size.width;
    const sh: number = sInfo.size.height;
    const sBytes: ArrayBuffer = new ArrayBuffer(sourceImage.getPixelBytesNumber());
    await sourceImage.readPixelsToBuffer(sBytes);
    const src: Uint8Array = new Uint8Array(sBytes);

    // 2) 读取遮罩信息与像素
    const mInfo = maskImage.getImageInfoSync();
    const mw: number = mInfo.size.width;
    const mh: number = mInfo.size.height;
    const mBytes: ArrayBuffer = new ArrayBuffer(maskImage.getPixelBytesNumber());
    await maskImage.readPixelsToBuffer(mBytes);
    const mask: Uint8Array = new Uint8Array(mBytes);

    // 3) 生成输出缓冲（RGBA_8888）
    const out: Uint8Array = new Uint8Array(sw * sh * 4);
    for (let y = 0; y < sh; y++) {
      for (let x = 0; x < sw; x++) {
        const si: number = (y * sw + x) * 4;
        out[si] = src[si];
        out[si + 1] = src[si + 1];
        out[si + 2] = src[si + 2];
        out[si + 3] = StickerProcessor.maskAlphaAt(mask, mw, mh, x, y, sw, sh);
      }
    }

    // 4) 用处理后的字节创建新 PixelMap
    const opts: image.InitializationOptions = {
      size: { width: sw, height: sh },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    };
    return await image.createPixelMap(out.buffer as ArrayBuffer, opts);
  }

  /**
   * 取遮罩在 (x,y)（原图坐标）处应贡献的透明度 0~255
   * - 同尺寸走直通；异尺寸用最近邻
   * - 优先用遮罩 Alpha；若遮罩全局不透明（纯白底图），则用亮度作为透明度
   */
  private static maskAlphaAt(mask: Uint8Array, mw: number, mh: number,
    x: number, y: number, sw: number, sh: number): number {
    // 坐标映射：遮罩 → 原图（最近邻）
    let mx: number = x;
    let my: number = y;
    if (mw !== sw || mh !== sh) {
      mx = Math.min(mw - 1, Math.floor(x * mw / sw));
      my = Math.min(mh - 1, Math.floor(y * mh / sh));
    }
    const i: number = (my * mw + mx) * 4;
    const a: number = mask[i + 3];
    // 遮罩带真实透明通道 → 直接用
    if (a > 0 && a < 255) {
      return a;
    }
    // 遮罩不透明（黑白图）→ 用亮度近似透明度（白=前景 255，黑=背景 0）
    const lum: number = (mask[i] + mask[i + 1] + mask[i + 2]) / 3;
    if (a === 0) {
      return lum >= 128 ? 255 : 0; // 全透明遮罩按灰度硬判
    }
    return Math.min(255, Math.max(0, Math.round(lum)));
  }
}
