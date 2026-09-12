/**
 * CropGeometry —— 裁剪框几何计算（从 ImageEditor 抽出的纯函数，无 UI 依赖，便于单测）
 */
import { HandleBase, DispRect, CropRect } from './EditorModels';
import { CROP_MIN } from './EditorConstants';

/** 裁剪比例文案转宽/高数值，自由裁剪返回 0 */
export function cropRatioValue(ratio: string): number {
  if (ratio === '1:1') {
    return 1;
  }
  if (ratio === '4:3') {
    return 4 / 3;
  }
  if (ratio === '3:4') {
    return 3 / 4;
  }
  if (ratio === '16:9') {
    return 16 / 9;
  }
  if (ratio === '9:16') {
    return 9 / 16;
  }
  return 0;
}

/**
 * 八把手拖拽后的选区计算：
 * @param base 拖拽开始时的选区
 * @param type 0=左上 1=右上 2=左下 3=右下（角点，对角边固定）
 *             4=上边中点 5=右边中点 6=下边中点 7=左边中点（边点，对边固定）
 * @param dx   手势水平位移
 * @param dy   手势垂直位移
 * @param disp 图片实际显示区域（边界）
 * @param ratio 固定宽/高比，0 表示自由裁剪
 */
export function calcCropRect(base: HandleBase, type: number, dx: number, dy: number,
  disp: DispRect, ratio: number): CropRect {
  const maxX: number = disp.x + disp.w;
  const maxY: number = disp.y + disp.h;

  // 拖拽后的四条边
  let left: number = base.x;
  let top: number = base.y;
  let right: number = base.x + base.w;
  let bottom: number = base.y + base.h;

  if (type === 0) {            // 左上角
    left = base.x + dx;
    top = base.y + dy;
  } else if (type === 1) {     // 右上角
    right = base.x + base.w + dx;
    top = base.y + dy;
  } else if (type === 2) {     // 左下角
    left = base.x + dx;
    bottom = base.y + base.h + dy;
  } else if (type === 3) {     // 右下角
    right = base.x + base.w + dx;
    bottom = base.y + base.h + dy;
  } else if (type === 4) {     // 上边中点：只改 top
    top = base.y + dy;
  } else if (type === 5) {     // 右边中点：只改 right
    right = base.x + base.w + dx;
  } else if (type === 6) {     // 下边中点：只改 bottom
    bottom = base.y + base.h + dy;
  } else if (type === 7) {     // 左边中点：只改 left
    left = base.x + dx;
  }

  // 边界 + 最小尺寸约束
  left = Math.max(disp.x, Math.min(left, right - CROP_MIN));
  right = Math.min(maxX, Math.max(right, left + CROP_MIN));
  top = Math.max(disp.y, Math.min(top, bottom - CROP_MIN));
  bottom = Math.min(maxY, Math.max(bottom, top + CROP_MIN));

  let w: number = right - left;
  let h: number = bottom - top;

  // 固定比例：以手势拖拽方向的对边为锚点，联动收缩
  if (ratio > 0) {
    // 边把手：只拖了一条边，按比例联动另一条边
    if (type === 4 || type === 6) {
      // 上/下边拖动 → h 变化 → w = h * ratio，水平居中
      w = h * ratio;
      if (w > disp.w) {
        w = disp.w;
        h = w / ratio;
        top = bottom - h;
      }
      // 水平居中（基于当前选区中心而非 base，避免拖拽中跳动）
      const center: number = base.x + base.w / 2;
      left = center - w / 2;
    } else if (type === 5 || type === 7) {
      // 左/右边拖动 → w 变化 → h = w / ratio，垂直居中
      h = w / ratio;
      if (h > disp.h) {
        h = disp.h;
        w = h * ratio;
      }
      // 垂直居中（基于当前选区中心，避免跳动）
      const vcenter: number = base.y + base.h / 2;
      top = vcenter - h / 2;
    } else {
      // 角把手：原有逻辑
      if (w / h > ratio) {
        w = h * ratio;
      } else {
        h = w / ratio;
      }
      // 以拖拽角的对角为锚点
      let maxW: number = maxX - left;
      let maxH: number = maxY - top;
      if (type === 0) {
        maxW = right - disp.x;
        maxH = bottom - disp.y;
      } else if (type === 1) {
        maxW = maxX - left;
        maxH = bottom - disp.y;
      } else if (type === 2) {
        maxW = right - disp.x;
        maxH = maxY - top;
      }
      const grow: number = CROP_MIN / Math.min(w, h);
      const fit: number = Math.min(maxW / w, maxH / h);
      const s: number = Math.min(Math.max(1, grow), fit);
      w = w * s;
      h = h * s;
      if (type === 0) {
        left = right - w;
        top = bottom - h;
      } else if (type === 1) {
        right = left + w;
        top = bottom - h;
      } else if (type === 2) {
        left = right - w;
        bottom = top + h;
      } else {
        right = left + w;
        bottom = top + h;
      }
    }
  }

  return { x: left, y: top, w: w, h: h };
}
