/**
 * ⚠️ 已废弃 / 无调用方（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：仅被同样废弃的 PhotoEditorPage 使用，而该页面没有任何入口。
 * 替代：编辑能力已经由 ImageEditor + common/editor/* 完整实现并上线。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */

/**
 * EditState.ets — 非破坏性编辑状态模型
 *
 * 所有编辑参数都保存在这个对象里，导出时通过逆变换映射回原图坐标。
 * 原图永不被修改，只保存此 JSON。
 */

/** 二维向量 */
export interface Vec2 {
  x: number;
  y: number;
}

/** 矩形（视图坐标 vp） */
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * 编辑状态：非破坏性保存的全部参数
 *
 * 视图坐标 = 预览区左上角为原点的 vp 坐标
 * 图像坐标 = 原图左上角为原点的 px 坐标
 */
export interface EditState {
  /** EXIF 方向标记 1-8（TIFF/EXIF Orientation 规范） */
  exifOrientation: number;
  /** 用户旋转角度（度），0 为基准，正值顺时针 */
  rotation: number;
  /** 用户缩放倍数，1.0 = 适配预览区 */
  scale: number;
  /** 用户平移量（视图坐标 vp） */
  translation: Vec2;
  /** 裁剪框（视图坐标 vp，相对于预览区左上角） */
  cropRect: Rect;
  /** 宽高比约束，null = 自由比例 */
  aspectRatio: number | null;
  /**
   * 透视校正四点（视图坐标 vp），undefined = 不校正
   * 顺序：左上、右上、右下、左下
   */
  perspectiveQuad: Vec2[] | undefined;
}

/**
 * EditState 工厂：根据预览区尺寸和原图尺寸生成初始状态
 */
export class EditStateFactory {
  /**
   * 创建默认编辑状态：裁剪框 = 图片 Contain 适配后的完整区域
   *
   * @param viewW 预览区宽度（vp）
   * @param viewH 预览区高度（vp）
   * @param imgW 原图宽度（px）
   * @param imgH 原图高度（px）
   */
  static createDefault(viewW: number, viewH: number, imgW: number, imgH: number): EditState {
    // Contain 适配：图片完整显示在预览区内，取较小缩放比
    const viewRatio = viewW / viewH;
    const imgRatio = imgW / imgH;

    let cropW: number;
    let cropH: number;
    if (imgRatio > viewRatio) {
      // 图片更宽 → 以宽度为准
      cropW = viewW;
      cropH = viewW / imgRatio;
    } else {
      // 图片更高 → 以高度为准
      cropH = viewH;
      cropW = viewH * imgRatio;
    }

    // 居中
    const cropX = (viewW - cropW) / 2;
    const cropY = (viewH - cropH) / 2;

    return {
      exifOrientation: 1,
      rotation: 0,
      scale: 1,
      translation: { x: 0, y: 0 },
      cropRect: { x: cropX, y: cropY, width: cropW, height: cropH },
      aspectRatio: null,
      perspectiveQuad: undefined
    };
  }

  /** 深拷贝 */
  static clone(state: EditState): EditState {
    return {
      exifOrientation: state.exifOrientation,
      rotation: state.rotation,
      scale: state.scale,
      translation: { x: state.translation.x, y: state.translation.y },
      cropRect: {
        x: state.cropRect.x,
        y: state.cropRect.y,
        width: state.cropRect.width,
        height: state.cropRect.height
      },
      aspectRatio: state.aspectRatio,
      perspectiveQuad: state.perspectiveQuad
        ? state.perspectiveQuad.map((p: Vec2) => ({ x: p.x, y: p.y }))
        : undefined
    };
  }

  /** 重置为初始状态（保留 exifOrientation） */
  static reset(state: EditState, viewW: number, viewH: number, imgW: number, imgH: number): EditState {
    const fresh = EditStateFactory.createDefault(viewW, viewH, imgW, imgH);
    fresh.exifOrientation = state.exifOrientation; // 保留 EXIF 方向
    return fresh;
  }
}
