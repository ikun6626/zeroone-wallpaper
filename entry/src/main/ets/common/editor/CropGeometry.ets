/**
 * CropGeometry —— 裁剪框几何计算（从 ImageEditor 抽出的纯函数，无 UI 依赖，便于单测）
 */
import { HandleBase, DispRect, CropRect } from './EditorModels';
import { CROP_MIN } from './EditorConstants';
import { LayerPoint } from './LayerGeometry';

/**
 * CropView —— 裁剪态的"视图侧"参数（与 ImageEditor 的状态一一对应）
 *
 * 关键约定（此前三个 bug 的根源都在这条约定上）：
 *  图片始终按 **预览区** 做 contain 适配（`disp`），用户缩放/平移/旋转都发生在这个坐标系里：
 *      screen = C + k · R(θ) · (disp.origin + (u,v)·s − C) + offset
 *  其中 C = 预览区中心，s = disp.scale（vp/源像素），k = 用户缩放，u,v = 源图像素。
 *  如果图片改成"按选区适配"，display 尺寸一变图片就自己跳，且这套逆运算全部失效。
 */
export interface CropView {
  disp: DispRect;
  previewW: number;
  previewH: number;
  /** 用户缩放倍数（cropScale） */
  scale: number;
  /** 用户平移（cropOffsetX，vp） */
  offsetX: number;
  /** 用户平移（cropOffsetY，vp） */
  offsetY: number;
  /** 旋转角度（度，顺时针为正） */
  angle: number;
  /** 水平镜像（绕图片中心） */
  flipH: boolean;
  /** 垂直镜像 */
  flipV: boolean;
}

/** 裁剪输出尺寸（源图像素） */
export interface CropSize {
  width: number;
  height: number;
}

/**
 * 离屏绘制参数：把源图按与 UI **完全相同** 的变换画进输出画布，
 * 使选区左上角恰好落在画布 (0,0)，画布尺寸 = cropOutputSize。
 */
export interface CropDrawTransform {
  /** 平移（输出画布像素） */
  tx: number;
  ty: number;
  /** 源图 1 像素 → 输出画布像素的倍数 */
  scale: number;
  /** 旋转弧度（顺时针为正，与 Canvas rotate 一致） */
  radians: number;
  /** 水平镜像系数（1 正常，-1 镜像） */
  sx: number;
  /** 垂直镜像系数 */
  sy: number;
}

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

/** 选区上 1 vp 对应多少源图像素（= disp.scale × 用户缩放）；这也是输出画布的像素比 */
function cropPixelRatio(view: CropView): number {
  const s: number = view.disp.scale > 0 ? view.disp.scale : 1;
  const k: number = view.scale > 0 ? view.scale : 1;
  return s * k;
}

/**
 * 图片旋转后覆盖目标区域所需的最小总缩放
 *
 * 用途：裁剪态下点 90° 旋转按钮 / 拉直滑条，框不动、图转。
 * 旋转后图片的轴对齐包围盒可能盖不住预览区（竖图转 90 后必然露黑），
 * 据此自动放大（与 iOS 照片一致）：
 *   AABB 宽 = disp.w·|cosθ| + disp.h·|sinθ|
 *   AABB 高 = disp.w·|sinθ| + disp.h·|cosθ|
 *   k = max(needW/AABB.w, needH/AABB.h)
 *
 * @param needW 需要覆盖的宽（vp，通常是预览宽）
 * @param needH 需要覆盖的高（vp）
 * @returns 建议的总 cropScale（≥1；调用方与当前缩放取 max）
 */
export function autoCropScale(view: CropView, needW: number, needH: number): number {
  const rad: number = view.angle * Math.PI / 180;
  const ac: number = Math.abs(Math.cos(rad));
  const as: number = Math.abs(Math.sin(rad));
  const aabbW: number = view.disp.w * ac + view.disp.h * as;
  const aabbH: number = view.disp.w * as + view.disp.h * ac;
  const k: number = Math.max(needW / (aabbW > 0 ? aabbW : 1),
    needH / (aabbH > 0 ? aabbH : 1));
  return Math.max(1, k);
}

/**
 * 裁剪输出尺寸：选区在源图像素下的实际尺寸
 *
 * 这张图与"选区看起来多大"无关，只由源图密度决定 —— 用户放大到 2 倍再裁一小块，
 * 得到的是那一小块的原分辨率图像，而不是被放大后的模糊图。
 */
export function cropOutputSize(rect: CropRect, view: CropView): CropSize {
  const m: number = cropPixelRatio(view);
  return {
    width: Math.max(1, Math.round(rect.w / m)),
    height: Math.max(1, Math.round(rect.h / m))
  };
}

/**
 * 计算离屏绘制参数（cropOutputSize 的配套）
 *
 * 推导：屏幕上图片原点 = C + k·R(θ)·(disp.origin − C) + offset；
 * 输出画布原点取选区左上角，因此整体减去 rect.origin。
 *
 * ⚠️ 注意单位：返回的 tx/ty 是**预览坐标系（vp）**，scale 是"1 源像素 = 多少 vp"
 * （= cropPixelRatio）。它描述的是一张 **vp 尺度**的画布。
 * 输出画布是源图像素尺度（见 cropOutputSize），要换算一次才对得上 —— 见 cropComposeTransform。
 */
export function cropDrawTransform(rect: CropRect, view: CropView): CropDrawTransform {
  const k: number = view.scale > 0 ? view.scale : 1;
  const cx: number = view.previewW / 2;
  const cy: number = view.previewH / 2;
  const radians: number = view.angle * Math.PI / 180;
  const cos: number = Math.cos(radians);
  const sin: number = Math.sin(radians);
  const dx: number = view.disp.x - cx;
  const dy: number = view.disp.y - cy;
  const ax: number = cx + k * (dx * cos - dy * sin) + view.offsetX;
  const ay: number = cy + k * (dx * sin + dy * cos) + view.offsetY;
  return {
    tx: ax - rect.x,
    ty: ay - rect.y,
    scale: cropPixelRatio(view),
    radians: radians,
    sx: view.flipH ? -1 : 1,
    sy: view.flipV ? -1 : 1
  };
}

/**
 * 输出画布坐标系里的绘制变换 —— composeCropToPixelMap() 的唯一出处
 *
 * 与 cropDrawTransform 的区别只有单位：输出画布是**源图像素尺度**（cropOutputSize
 * 把选区的 vp 尺寸除以 cropPixelRatio），而 cropDrawTransform 给的是 vp 尺度的平移
 * 与"1 源像素 = 多少 vp"的比值。所以这里要再做一次
 *     vp → 输出像素：1 vp = (1 / cropPixelRatio) 源像素 = (cap / cropPixelRatio) 画布像素
 * 换算：画布 1:1 对应源像素（cap 是长边护栏带来的额外缩放）。
 *
 * 少了这一步会发生什么（就是"裁完只剩左上角一小块、四周一片黑"那个 bug）：
 * 画布按源像素开好了（例如 1067×800），却用 vp 尺度的 scale（例如 0.3）去画，
 * 结果源图只画到画布的三分之一不到，其余全是被 fillRect 铺的底色。
 */
export function cropComposeTransform(rect: CropRect, view: CropView, cap: number): CropDrawTransform {
  const t: CropDrawTransform = cropDrawTransform(rect, view);
  const m: number = cropPixelRatio(view);
  // vp → 输出画布像素；m 理论上恒 > 0，这里只是防御退化输入
  const k: number = m > 0 ? cap / m : cap;
  return {
    tx: t.tx * k,
    ty: t.ty * k,
    scale: cap,
    radians: t.radians,
    sx: t.sx,
    sy: t.sy
  };
}

/**
 * 输出画布像素 → 源图像素（cropDrawTransform 的逆运算）
 *
 * 用途：裁剪后把文字/贴纸的锚点从旧图像素换算到新图像素。
 * 此前用 `mapCrop` 简单减偏移，只有在"没缩放、没旋转"时才碰巧正确。
 */
export function unprojectCrop(x: number, y: number, t: CropDrawTransform,
  baseW: number, baseH: number): LayerPoint {
  const dx: number = x - t.tx;
  const dy: number = y - t.ty;
  const cos: number = Math.cos(-t.radians);
  const sin: number = Math.sin(-t.radians);
  const m: number = t.scale > 0 ? t.scale : 1;
  // 先逆旋转/缩放 → 图片绘制坐标
  const X: number = (dx * cos - dy * sin) / m;
  const Y: number = (dx * sin + dy * cos) / m;
  // 再逆镜像（镜像自逆，绕图片中心）
  return {
    x: t.sx < 0 ? baseW - X : X,
    y: t.sy < 0 ? baseH - Y : Y
  };
}
