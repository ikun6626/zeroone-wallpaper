/**
 * PerspectiveTask —— 水平/垂直透视校正（TaskPool 像素重采样）
 *
 * 对应 iOS 照片裁剪里的「水平 / 垂直」校正（拍楼时把梯形拉回矩形）。
 *
 * 数学（归一化坐标，图片四角 0~1）：
 *  正映射（源→目标）：d = 1 + px·nx + py·ny
 *      nx' = nx/d, ny' = ny/d
 *  逆映射（目标→源，逐像素采样用）：d' = 1 − px·nx' − py·ny'
 *      nx = nx'/d', ny = ny'/d'
 *  其中 px = 水平强度 × 0.12（满档 12% 透视量）。
 *
 * 双线性插值；越界位置 clamp 到边缘像素（与系统照片一致，不留黑边）。
 * 输出到新缓冲（不能原地：采样会读到已写像素）。
 */

/**
 * 透视校正（TaskPool 入口）
 * @param bytes 源 RGBA_8888 像素缓冲（只读）
 * @param w     图宽
 * @param h     图高
 * @param levelH 水平强度 -100~100
 * @param levelV 垂直强度 -100~100
 * @returns 校正后的新 RGBA 缓冲
 */
@Concurrent
export function runPerspectiveTask(bytes: ArrayBuffer, w: number, h: number,
  levelH: number, levelV: number): ArrayBuffer {
  const src: Uint8Array = new Uint8Array(bytes);
  const out: Uint8Array = new Uint8Array(new ArrayBuffer(src.length));

  const px: number = (levelH / 100) * 0.12;
  const py: number = (levelV / 100) * 0.12;
  const maxX: number = w - 1;
  const maxY: number = h - 1;

  for (let y = 0; y < h; y++) {
    // 目标归一化坐标（用 (w-1)/(h-1) 映射四角，避免边缘缩掉一个像素）
    const nyp: number = h > 1 ? y / maxY : 0;
    for (let x = 0; x < w; x++) {
      const nxp: number = w > 1 ? x / maxX : 0;
      const d: number = 1 - px * nxp - py * nyp;
      // 退化（d≈0：图片被折成线）保护
      let fnx: number = Math.abs(d) > 1e-6 ? nxp / d : nxp;
      let fny: number = Math.abs(d) > 1e-6 ? nyp / d : nyp;
      let sx: number = fnx * maxX;
      let sy: number = fny * maxY;
      // 越界 clamp 到边缘
      sx = sx < 0 ? 0 : (sx > maxX ? maxX : sx);
      sy = sy < 0 ? 0 : (sy > maxY ? maxY : sy);

      // 双线性插值
      const x0: number = sx | 0;
      const y0: number = sy | 0;
      const x1: number = x0 + 1 > maxX ? maxX : x0 + 1;
      const y1: number = y0 + 1 > maxY ? maxY : y0 + 1;
      const tx: number = sx - x0;
      const ty: number = sy - y0;

      const i00: number = (y0 * w + x0) * 4;
      const i10: number = (y0 * w + x1) * 4;
      const i01: number = (y1 * w + x0) * 4;
      const i11: number = (y1 * w + x1) * 4;
      const o: number = (y * w + x) * 4;

      for (let c = 0; c < 4; c++) {
        const top: number = src[i00 + c] * (1 - tx) + src[i10 + c] * tx;
        const bot: number = src[i01 + c] * (1 - tx) + src[i11 + c] * tx;
        let v: number = top * (1 - ty) + bot * ty;
        v = v < 0 ? 0 : (v > 255 ? 255 : v);
        out[o + c] = v | 0;
      }
    }
  }
  return out.buffer;
}
