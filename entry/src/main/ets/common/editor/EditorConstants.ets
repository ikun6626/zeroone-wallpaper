/**
 * EditorConstants —— 图片编辑器常量（从 ImageEditor 抽出）
 */

/** 基础滤镜 */
export const BASE_FILTERS: string[] = ['原图', '黑白', '复古', '暖色', '冷色', '胶片', '清新', '反转', '鲜艳', '粉彩', '暮色', '褪色', '暗角'];
/** 风格化滤镜（艺术风格近似） */
export const STYLE_FILTERS: string[] = ['水墨', '油画', '印象派', '剪纸', '乐高', '金属', '毛绒'];
/** 全部滤镜 */
export const FILTERS: string[] = BASE_FILTERS.concat(STYLE_FILTERS);
/** 纹理效果 */
export const TEXTURES: string[] = ['纸纹', '水彩纸纹', '噪点', '光晕', '污渍'];
/** 文字颜色 */
export const TEXT_COLORS: string[] = ['#FFFFFF', '#C9333D', '#333333', '#FFD700', '#4CAF50', '#2196F3'];
/** 文字风格 */
export const TEXT_STYLES: string[] = ['无', '阴影', '发光', '描边'];
/** 主题文字预置文案 */
export const THEME_PHRASES: string[] = ['今日宜吸猫', '不想上班', '周一也要元气满满', '周末快乐', '晚安 好梦', '今天也要加油鸭', '想见你', '摸鱼中...'];
/** 励志语录预置文案 */
export const QUOTE_PHRASES: string[] = ['生活明朗 万物可爱', '保持热爱 奔赴山海', '温柔且坚定', '慢慢来 比较快', '万事胜意', '未来可期', '每天都值得被爱', '所爱隔山海 山海皆可平'];
/** 裁剪框最小尺寸 */
export const CROP_MIN: number = 60;
/** 画布适配：铺满（cover，裁掉超出部分；壁纸默认） */
export const FIT_MODE_COVER: string = 'cover';
/** 画布适配：完整显示（contain，留白用模糊底图填充） */
export const FIT_MODE_CONTAIN: string = 'contain';
