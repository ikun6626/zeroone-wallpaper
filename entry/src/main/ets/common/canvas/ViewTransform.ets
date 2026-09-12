/**
 * ViewTransform —— 底图变换与几何换算（纯函数，不依赖 UI / 系统 API）
 *
 * 要解决的问题：预览、编辑、导出此前各写一套坐标（预览用 Contain 完整显示原图、
 * 保存直接落原图、图层各自记绝对像素），于是"预览看到的"和"存下来的"永远对不上。
 *
 * 本模块确立三条规矩：
 *  1. **一切以画布为基准**：画布 = 目标设备的屏幕像素尺寸（见 `CanvasSpec`）。
 *  2. **变换用归一化表达**：`scale` 是相对 cover 基准的倍数，`offsetX/offsetY` 以画布尺寸为单位，
 *     因此同一份编辑数据在任意分辨率的设备上都能还原成同样的构图——这是"画布跟随设备"的前提。
 *  3. **只支持 90° 步进旋转与镜像**：90° 的整数倍在像素上精确可逆；任意角度会产生半像素误差，
 *     需要时由导出侧在离屏画布上叠加，不进这套几何。
 *
 * 本文件刻意不 import 任何 `@kit.*`，所以可以被单元测试直接引用（见 `entry/src/test/`）。
 */

/** 矩形（坐标系由调用方约定：画布像素 / 原图像素） */
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 点坐标 */
export interface Point {
  x: number;
  y: number;
}

/** 尺寸 */
export interface Size {
  width: number;
  height: number;
}

/**
 * ViewTransform —— 用户对底图做的全部变换
 *
 * 语义：
 *  - `scale`：相对 cover 基准的额外缩放，`1` = 刚好铺满画布（不留黑边）
 *  - `offsetX/offsetY`：归一化平移，`1` = 平移一整个画布宽/高（正值向右 / 向下）
 *  - `quarterTurns`：90° 旋转圈数 0~3（顺时针）
 *  - `flipH/flipV`：水平 / 垂直镜像
 */
export class ViewTransform {
  scale: number;
  offsetX: number;
  offsetY: number;
  quarterTurns: number;
  flipH: boolean;
  flipV: boolean;

  constructor(scale: number = 1, offsetX: number = 0, offsetY: number = 0,
              quarterTurns: number = 0, flipH: boolean = false, flipV: boolean = false) {
    this.scale = scale;
    this.offsetX = offsetX;
    this.offsetY = offsetY;
    this.quarterTurns = quarterTurns;
    this.flipH = flipH;
    this.flipV = flipV;
  }

  /** 默认变换：铺满、居中、不旋转不镜像 */
  static identity(): ViewTransform {
    return new ViewTransform();
  }

  clone(): ViewTransform {
    return new ViewTransform(this.scale, this.offsetX, this.offsetY,
      this.quarterTurns, this.flipH, this.flipV);
  }

  /** 是否为"未做任何调整"的状态 */
  isIdentity(): boolean {
    return Math.abs(this.scale - 1) < 1e-6
      && Math.abs(this.offsetX) < 1e-6
      && Math.abs(this.offsetY) < 1e-6
      && ViewMath.normalizeTurns(this.quarterTurns) === 0
      && !this.flipH && !this.flipV;
  }
}

/**
 * ViewMath —— 底图几何换算
 *
 * 所有入参里的 `sw/sh` 指**原始底图**尺寸；需要 90° 旋转时先用 `orientedSize()`
 * 得到"摆正后"的有效尺寸，再用它参与后续计算（或按需在做完旋转的 PixelMap 上计算）。
 */
export class ViewMath {
  /** 覆盖式基准缩放（cover）：保证画布被完全填满 */
  static coverScale(sw: number, sh: number, cw: number, ch: number): number {
    if (sw <= 0 || sh <= 0 || cw <= 0 || ch <= 0) {
      return 1;
    }
    return Math.max(cw / sw, ch / sh);
  }

  /** 归一化旋转圈数到 0~3 */
  static normalizeTurns(quarterTurns: number): number {
    if (!Number.isFinite(quarterTurns)) {
      return 0;
    }
    const n: number = Math.round(quarterTurns) % 4;
    return n < 0 ? n + 4 : n;
  }

  /** 旋转 90° 步进后的有效尺寸（奇数圈宽高互换） */
  static orientedSize(sw: number, sh: number, quarterTurns: number): Size {
    const t: number = ViewMath.normalizeTurns(quarterTurns);
    return (t % 2 === 0) ? { width: sw, height: sh } : { width: sh, height: sw };
  }

  /**
   * 底图在画布坐标系里的绘制矩形
   * 画布中心为基准 + 归一化平移；`scale=1` 时恰好铺满画布
   */
  static drawRect(sw: number, sh: number, cw: number, ch: number, t: ViewTransform): Rect {
    const eff: number = ViewMath.coverScale(sw, sh, cw, ch) * t.scale;
    const dw: number = sw * eff;
    const dh: number = sh * eff;
    return {
      x: (cw - dw) / 2 + t.offsetX * cw,
      y: (ch - dh) / 2 + t.offsetY * ch,
      width: dw,
      height: dh
    };
  }

  /**
   * 画布对应的原图区域 —— "所见即所导"的唯一出处
   *
   * 预览铺满、导出（按画布）、导出（原图密度）三条路径都从这里取裁剪区域，
   * 因此不会再出现"预览一种构图、导出来另一种"。
   * 若 `scale < 1`（画布没被填满），返回的区域会被夹到原图边界内。
   */
  static sourceRect(sw: number, sh: number, cw: number, ch: number, t: ViewTransform): Rect {
    const d: Rect = ViewMath.drawRect(sw, sh, cw, ch, t);
    const eff: number = d.width / sw;
    if (eff <= 0) {
      return { x: 0, y: 0, width: sw, height: sh };
    }
    const sx: number = ViewMath.clampValue((0 - d.x) / eff, 0, sw);
    const sy: number = ViewMath.clampValue((0 - d.y) / eff, 0, sh);
    const ex: number = ViewMath.clampValue((cw - d.x) / eff, 0, sw);
    const ey: number = ViewMath.clampValue((ch - d.y) / eff, 0, sh);
    return {
      x: sx,
      y: sy,
      width: Math.max(ex - sx, 0),
      height: Math.max(ey - sy, 0)
    };
  }

  /** 归一化平移的上限：再拖就露出画布外的空白 */
  static maxOffsetX(sw: number, sh: number, cw: number, ch: number, t: ViewTransform): number {
    const dw: number = sw * ViewMath.coverScale(sw, sh, cw, ch) * t.scale;
    return dw <= cw ? 0 : (dw - cw) / (2 * cw);
  }

  /** 归一化平移的上限（纵向） */
  static maxOffsetY(sw: number, sh: number, cw: number, ch: number, t: ViewTransform): number {
    const dh: number = sh * ViewMath.coverScale(sw, sh, cw, ch) * t.scale;
    return dh <= ch ? 0 : (dh - ch) / (2 * ch);
  }

  /** 把平移夹回合法范围，返回新对象（不修改入参） */
  static clamp(sw: number, sh: number, cw: number, ch: number, t: ViewTransform): ViewTransform {
    const out: ViewTransform = t.clone();
    const mx: number = ViewMath.maxOffsetX(sw, sh, cw, ch, t);
    const my: number = ViewMath.maxOffsetY(sw, sh, cw, ch, t);
    out.offsetX = ViewMath.clampValue(t.offsetX, -mx, mx);
    out.offsetY = ViewMath.clampValue(t.offsetY, -my, my);
    return out;
  }

  /**
   * 拖拽：`dxVp/dyVp` 为手势位移（vp），`density` 为屏幕像素密度
   * 单位在内部一次性换算成 px，避免 vp/px 混用（画布是 px，手势是 vp）
   */
  static withDrag(sw: number, sh: number, cw: number, ch: number, t: ViewTransform,
                  dxVp: number, dyVp: number, density: number): ViewTransform {
    const out: ViewTransform = t.clone();
    const d: number = density > 0 ? density : 1;
    out.offsetX = t.offsetX + (dxVp * d) / cw;
    out.offsetY = t.offsetY + (dyVp * d) / ch;
    return ViewMath.clamp(sw, sh, cw, ch, out);
  }

  /**
   * 捏合缩放：`ratio` 为本次手势相对起点的倍数
   * 缩放后立即重新夹紧平移，保证不会拖出空白边
   */
  static withPinch(sw: number, sh: number, cw: number, ch: number, t: ViewTransform,
                   ratio: number, minScale: number = 1, maxScale: number = 5): ViewTransform {
    const out: ViewTransform = t.clone();
    out.scale = ViewMath.clampValue(t.scale * ratio, minScale, maxScale);
    return ViewMath.clamp(sw, sh, cw, ch, out);
  }

  /**
   * 数值夹取
   *
   * ⚠️ 命名不能叫 `clamp`：ArkTS 不允许同名的两个方法实现（哪怕参数个数不同），
   *    本类里已有一个做变换夹取的 `clamp(...)`，故数值版必须另起名字。
   */
  static clampValue(v: number, lo: number, hi: number): number {
    if (lo > hi) {
      return lo;
    }
    if (v < lo) {
      return lo;
    }
    return v > hi ? hi : v;
  }

  /**
   * 导出尺寸护栏：等比缩放到长边不超过 `maxLongEdge`
   * 4000×6000 的 RGBA 位图约 96MB，原图导出必须过这一道
   */
  static limitLongEdge(width: number, height: number, maxLongEdge: number): Size {
    const longEdge: number = Math.max(width, height);
    if (longEdge <= 0) {
      return { width: Math.round(width), height: Math.round(height) };
    }
    if (longEdge <= maxLongEdge) {
      return { width: Math.round(width), height: Math.round(height) };
    }
    const k: number = maxLongEdge / longEdge;
    return { width: Math.round(width * k), height: Math.round(height * k) };
  }

  /**
   * 预览区里允许的最大平移量（vp / px 均可，只要与 `extent` 同单位）
   *
   * 依据：图片按 cover 铺满后尺寸恰好等于可视区，放大 `scale` 倍时四周各多出
   * `(scale-1) * extent / 2`，这就是能拖动的余量；`scale <= 1` 时没有余量。
   * 预览侧用它夹紧手势位移，保证图片永远盖满可视区、不露黑边。
   */
  static maxPan(scale: number, extent: number): number {
    const s: number = (scale > 1) ? scale : 1;
    return ((s - 1) * extent) / 2;
  }
}

/**
 * LayerMath —— 文字 / 贴纸图层的归一化坐标
 *
 * 图层位置一律存**归一化值**（0~1，相对画布左上角），尺寸以画布宽度为参照。
 * 这样换设备（1080×2340 → 1284×2778）时图层会等比跟随，而不是漂到画外。
 */
export class LayerMath {
  /** 归一化坐标 → 画布像素 */
  static toCanvas(nx: number, ny: number, cw: number, ch: number): Point {
    return { x: nx * cw, y: ny * ch };
  }

  /** 画布像素 → 归一化坐标 */
  static toNormalized(x: number, y: number, cw: number, ch: number): Point {
    return {
      x: cw > 0 ? x / cw : 0,
      y: ch > 0 ? y / ch : 0
    };
  }

  /** 归一化长度 → 画布像素（以画布宽度为参照，保证等比） */
  static sizeToCanvas(normalizedSize: number, cw: number): number {
    return normalizedSize * cw;
  }

  /** 画布像素长度 → 归一化长度 */
  static sizeToNormalized(px: number, cw: number): number {
    return cw > 0 ? px / cw : 0;
  }

  /** 夹到 [0,1]，避免图层被拖到画布外丢不见 */
  static clamp01(v: number): number {
    return ViewMath.clampValue(v, 0, 1);
  }
}
