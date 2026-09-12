/**
 * EditorModels —— 图片编辑器的数据模型（从 ImageEditor 抽出）
 */

/** 文字叠加项 */
export interface TextItem {
  content: string;
  color: string;
  x: number;
  y: number;
  scale: number;
  style: number; // 0=无 1=阴影 2=发光 3=描边
}

/** 贴纸叠加项（抠图/相册 PNG 贴纸文件路径） */
export interface StickerItem {
  content: string;
  x: number;
  y: number;
  scale: number;
  /**
   * 旋转角度（度，绕贴纸中心，顺时针）
   * 工作台/画板早就支持双指旋转，编辑器此前没有这个字段 →
   * 用户在这里摆不出斜着的贴纸，导出也就无从谈起（审计 M4）。
   */
  angle: number;
}

/** 裁剪框角点拖拽起点（位置+尺寸） */
export interface HandleBase {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 图片实际显示区域（含缩放比） */
export interface DispRect {
  x: number;
  y: number;
  w: number;
  h: number;
  scale: number;
}

/** 裁剪选区计算结果（位置+尺寸） */
export interface CropRect {
  x: number;
  y: number;
  w: number;
  h: number;
}
