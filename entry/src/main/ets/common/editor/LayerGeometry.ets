/**
 * LayerGeometry —— 叠加图层（文字/贴纸）在「屏幕坐标」与「图片像素坐标」间的映射，
 * 以及裁剪 / 旋转 / 翻转后锚点的重映射（纯函数，无 UI 依赖）。
 *
 * 坐标模型：
 *  - 图层在预览 Stack 内居中，translate(x, y) 是相对预览区中心的 vp 偏移；
 *  - dispRect() 给出图片在预览区内的显示矩形（vp）及 vp/像素 缩放比 scale；
 *  - 几何变换前把图层位置换算成图片像素锚点，变换后再反算回 vp，
 *    这样文字/贴纸会像“印”在画面内容上一样跟随裁剪、旋转、翻转。
 */
import { DispRect } from './EditorModels';

/** 二维点（在不同函数里语义为 vp 偏移或像素坐标，由参数名/注释区分） */
export interface LayerPoint {
  x: number;
  y: number;
}

/**
 * 图层 translate 偏移（相对预览区中心，vp）→ 图片像素锚点
 * 容器坐标点 = (previewW/2 + tx, previewH/2 + ty)
 * 像素点     = (容器坐标点 - disp 原点) / disp.scale
 */
export function toAnchor(tx: number, ty: number, disp: DispRect,
  previewW: number, previewH: number): LayerPoint {
  const u: number = (previewW / 2 + tx - disp.x) / disp.scale;
  const v: number = (previewH / 2 + ty - disp.y) / disp.scale;
  return { x: u, y: v };
}

/** 图片像素锚点 → 图层 translate 偏移（toAnchor 的逆运算） */
export function fromAnchor(u: number, v: number, disp: DispRect,
  previewW: number, previewH: number): LayerPoint {
  const tx: number = disp.x + u * disp.scale - previewW / 2;
  const ty: number = disp.y + v * disp.scale - previewH / 2;
  return { x: tx, y: ty };
}

/** 像素锚点限制在图片范围内（变换后落在被裁掉区域的图层贴到最近边缘，不擅自删除） */
export function clampAnchor(p: LayerPoint, w: number, h: number): LayerPoint {
  const x: number = Math.max(0, Math.min(p.x, Math.max(0, w - 1)));
  const y: number = Math.max(0, Math.min(p.y, Math.max(0, h - 1)));
  return { x: x, y: y };
}

/** 裁剪映射：裁掉左上角 cropX/cropY 像素，锚点平移 */
export function mapCrop(p: LayerPoint, cropX: number, cropY: number): LayerPoint {
  return { x: p.x - cropX, y: p.y - cropY };
}

/**
 * 旋转映射（与 PixelMap.rotate 的顺时针约定一致）
 * @param angle 旋转角度（UI 只产生 ±90；180/270 做了兼容）
 * @param oldW 旋转前像素宽
 * @param oldH 旋转前像素高
 */
export function mapRotate(p: LayerPoint, angle: number, oldW: number, oldH: number): LayerPoint {
  // 归一到 [0,360)
  let a: number = angle % 360;
  if (a < 0) {
    a += 360;
  }
  if (a === 90) {
    // 顺时针 90：新尺寸 oldH × oldW
    return { x: oldH - 1 - p.y, y: p.x };
  }
  if (a === 270) {
    // 逆时针 90
    return { x: p.y, y: oldW - 1 - p.x };
  }
  if (a === 180) {
    return { x: oldW - 1 - p.x, y: oldH - 1 - p.y };
  }
  return { x: p.x, y: p.y };
}

/** 翻转映射：horizontal 左右镜像，vertical 上下镜像 */
export function mapFlip(p: LayerPoint, horizontal: boolean, vertical: boolean,
  oldW: number, oldH: number): LayerPoint {
  return {
    x: horizontal ? oldW - 1 - p.x : p.x,
    y: vertical ? oldH - 1 - p.y : p.y
  };
}
