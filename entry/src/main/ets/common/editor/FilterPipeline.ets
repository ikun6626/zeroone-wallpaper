/**
 * FilterPipeline —— 滤镜/纹理"激活态"的纯规则（阶段 5 问题四）
 *
 * 编辑器改成**非破坏式管线**之后，画面永远等于：
 *
 *     底图（只烘焙几何：旋转/翻转/裁剪）→ 滤镜 → 纹理 → 显示 / 导出
 *
 * 于是"激活哪个滤镜/纹理"就是全部状态，规则只有两条（放在这里是为了能被单测覆盖）：
 *  1. 点当前已激活的那一项 → 取消它（滤镜回 '原图'，纹理回 ''）；
 *  2. 点别的项 → 换掉它，**不是叠加上去**（旧实现是"在当前图上再叠一层"，
 *     所以 复古 点两次 = 两层复古，复古→黑白 = 两种叠色）。
 */

/** 滤镜的"无"状态（与 EditorConstants.BASE_FILTERS 的第一项一致） */
export const NO_FILTER: string = '原图';
/** 纹理的"无"状态 */
export const NO_TEXTURE: string = '';

/** 点击某个滤镜后新的激活滤镜：再点一次同一个 = 取消 */
export function toggleFilter(current: string, tapped: string): string {
  return current === tapped ? NO_FILTER : tapped;
}

/** 点击某个纹理后新的激活纹理：再点一次同一个 = 取消 */
export function toggleTexture(current: string, tapped: string): string {
  return current === tapped ? NO_TEXTURE : tapped;
}
