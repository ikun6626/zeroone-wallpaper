/**
 * ⚠️ 已废弃 / 未完成（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：仅被同样废弃的 PhotoEditorPage 使用；且实现是 Phase-1 **占位**，
 *       逆变换的 TODO 尚未完成（未考虑旋转/EXIF），接通导出会导致裁切错位。
 * 替代：ImageEditor 的裁剪走 CropGeometry + dispRect 换算，已实测可用。
 * 若将来要复用它，**必须先补完 TODO 并写用例验证**，不要直接接线。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */

/**
 * CoordinateMapper.ets — 视图坐标 ↔ 图像坐标 映射工具
 *
 * 核心职责：
 * - 将裁剪框四角（视图坐标 vp）通过逆变换映射回原图像素坐标
 * - 支持旋转、缩放、平移、EXIF 方向的逆变换
 *
 * 坐标系约定：
 * - 视图坐标：预览区左上角为原点，单位 vp
 * - 图像坐标：原图左上角为原点，单位 px
 *
 * 变换链（正向）：图像 → EXIF校正 → 缩放 → 旋转 → 平移 → 视图
 * 逆变换（导出用）：视图 → 逆平移 → 逆旋转 → 逆缩放 → 逆EXIF → 图像
 */

import { Vec2, Rect, EditState } from '../model/EditState';

export class CoordinateMapper {
  /**
   * 视图坐标 → 图像像素坐标（逆变换）
   *
   * @param viewPoint 视图坐标点（vp）
   * @param state 当前编辑状态
   * @param dispW 图片在预览区中的显示宽度（px→vp 缩放后）
   * @param dispH 图片在预览区中的显示高度
   * @param viewW 预览区宽度（vp）
   * @param viewH 预览区高度（vp）
   * @param imgW 原图宽度（px）
   * @param imgH 原图高度（px）
   */
  static viewToImage(
    viewPoint: Vec2,
    state: EditState,
    dispW: number,
    dispH: number,
    viewW: number,
    viewH: number,
    imgW: number,
    imgH: number
  ): Vec2 {
    // TODO Phase 3: 实现完整逆变换
    // 1. 减去平移
    // 2. 逆旋转（-rotation）
    // 3. 逆缩放（/scale）
    // 4. 视图坐标 → 图像坐标（× imgW/dispW）

    // Phase 1 占位：简单线性映射
    const scaleX: number = imgW / dispW;
    const scaleY: number = imgH / dispH;
    return {
      x: (viewPoint.x - state.translation.x) * scaleX,
      y: (viewPoint.y - state.translation.y) * scaleY
    };
  }

  /**
   * 图像像素坐标 → 视图坐标（正向变换）
   */
  static imageToView(
    imgPoint: Vec2,
    state: EditState,
    dispW: number,
    dispH: number,
    viewW: number,
    viewH: number,
    imgW: number,
    imgH: number
  ): Vec2 {
    // TODO Phase 3: 实现完整正向变换
    const scaleX: number = dispW / imgW;
    const scaleY: number = dispH / imgH;
    return {
      x: imgPoint.x * scaleX + state.translation.x,
      y: imgPoint.y * scaleY + state.translation.y
    };
  }

  /**
   * 将视图坐标的裁剪框映射为图像像素坐标的裁剪区域
   * 用于导出时从原图裁剪
   *
   * @returns 图像坐标系下的裁剪区域（px）
   */
  static cropRectViewToImage(
    cropRect: Rect,
    state: EditState,
    dispW: number,
    dispH: number,
    viewW: number,
    viewH: number,
    imgW: number,
    imgH: number
  ): Rect {
    // TODO Phase 3: 考虑旋转后的裁剪框映射
    // Phase 1 占位：直接线性映射四角
    const tl: Vec2 = CoordinateMapper.viewToImage(
      { x: cropRect.x, y: cropRect.y },
      state, dispW, dispH, viewW, viewH, imgW, imgH
    );
    const br: Vec2 = CoordinateMapper.viewToImage(
      { x: cropRect.x + cropRect.width, y: cropRect.y + cropRect.height },
      state, dispW, dispH, viewW, viewH, imgW, imgH
    );

    // 确保不越界
    const x: number = Math.max(0, Math.min(imgW, Math.min(tl.x, br.x)));
    const y: number = Math.max(0, Math.min(imgH, Math.min(tl.y, br.y)));
    const w: number = Math.max(0, Math.min(imgW - x, Math.abs(br.x - tl.x)));
    const h: number = Math.max(0, Math.min(imgH - y, Math.abs(br.y - tl.y)));

    return { x, y, width: w, height: h };
  }

  /**
   * 根据 EXIF 方向标记修正图片显示方向
   * EXIF Orientation 1-8 的含义参见 TIFF 规范
   *
   * @param imgW 原图宽度
   * @param imgH 原图高度
   * @param orientation EXIF 方向标记
   * @returns 修正后的宽高 { width, height }
   */
  static applyExifSize(imgW: number, imgH: number, orientation: number): Vec2 {
    // orientation 5-8 需要交换宽高
    if (orientation >= 5 && orientation <= 8) {
      return { x: imgH, y: imgW }; // 宽高互换
    }
    return { x: imgW, y: imgH };
  }
}
