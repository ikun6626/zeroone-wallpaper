/**
 * ImageComposer —— 离屏画布合成（替代 componentSnapshot 截屏幕）
 *
 * 链路（对照本机 SDK 的 component/canvas.d.ts 核实）：
 *   new OffscreenCanvas(baseW, baseH)                         // 像素尺寸，构造仅 2 参
 *     → getContext('2d'): OffscreenCanvasRenderingContext2D
 *     → 该类继承 CanvasRenderer.getPixelMap(x,y,w,h): PixelMap  // 直接像素捕获
 * 依次绘制：底图（无灰边、原分辨率）→ 文字层 → 贴纸层，再 ImagePacker 打包 JPEG。
 *
 * 两个实测陷阱（都已避开）：
 *  1. transferToImageBitmap() 产出的 ImageBitmap 无法转 PixelMap
 *     （image.createImageSource 无此重载）——不用 ImageBitmap，直接 ctx.getPixelMap；
 *  2. 4 参构造 (w,h,settings,unit) 属于 OffscreenCanvasRenderingContext2D，
 *     屏幕绑定的 CanvasRenderingContext2D 构造只接受 (settings?)，单位枚举也不是全局值。
 *
 * 解决截图方案的三个问题：
 *   1. Contain 留白的 #EEEEEE 灰边不再入图；
 *   2. 导出分辨率 = 原图分辨率，不被屏幕降采样；
 *   3. 选中态红色 ✕ 是纯 UI，天然不会被画进照片。
 *
 * 坐标换算与 LayerGeometry 一致：图层 translate 是相对预览中心的 vp 偏移，
 * 通过 dispRect 的 scale 换算为图片像素；字号/贴纸盒边长同样除以 scale。
 */
import { image } from '@kit.ImageKit';
import { TextItem, StickerItem, DispRect, CropRect } from './EditorModels';
import { toAnchor, LayerPoint } from './LayerGeometry';
import { ViewTransform, ViewMath, Rect } from '../canvas/ViewTransform';
import { CropView, CropSize, CropDrawTransform, cropOutputSize, cropDrawTransform } from './CropGeometry';

/** 裁剪合成结果：像素图（所有权交给调用方）与实际输出尺寸 */
export interface CropComposeResult {
  pixelMap: image.PixelMap;
  width: number;
  height: number;
  /** 长边护栏带来的额外缩放（输出画布像素 / 未受限输出像素），换算图层锚点时要用 */
  canvasScale: number;
}

/** UI 端文字基准字号（fontSize = TEXT_BASE_FONT * scale，单位 vp） */
const TEXT_BASE_FONT: number = 22;
/** UI 端贴纸显示盒边长（130 * scale，单位 vp，objectFit: Contain） */
const STICKER_BOX: number = 130;
/** UI 端文字最大宽度 = previewW - 48(vp) */
const TEXT_SIDE_GAP: number = 48;
/** 多行行高倍数（贴近 ArkUI Text 默认排版） */
const LINE_HEIGHT: number = 1.3;

/** #RGB / #RRGGBB / #AARRGGBB → Canvas rgba() */
function toRgba(hex: string, alpha: number): string {
  let h: string = hex.replace('#', '');
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  let a: number = alpha;
  if (h.length === 3) {
    r = parseInt(h.charAt(0) + h.charAt(0), 16);
    g = parseInt(h.charAt(1) + h.charAt(1), 16);
    b = parseInt(h.charAt(2) + h.charAt(2), 16);
  } else {
    if (h.length === 8) {
      a = (parseInt(h.substring(0, 2), 16) / 255) * alpha;
      h = h.substring(2);
    }
    r = parseInt(h.substring(0, 2), 16);
    g = parseInt(h.substring(2, 4), 16);
    b = parseInt(h.substring(4, 6), 16);
  }
  return `rgba(${r},${g},${b},${a})`;
}

/** 是否为代理对高位码元（emoji 等需要两个 UTF-16 码元表示一个字符） */
function isHighSurrogate(code: number): boolean {
  return code >= 0xD800 && code <= 0xDBFF;
}

/** 是否属于"可逐字断行"的字符（CJK 汉字/假名/全角标点等） */
function isBreakableChar(code: number): boolean {
  return (code >= 0x2E80 && code <= 0x9FFF)     // CJK 部首扩展 ~ 统一表意文字
    || (code >= 0x3000 && code <= 0x303F)       // CJK 标点
    || (code >= 0xAC00 && code <= 0xD7AF)       // 谚文
    || (code >= 0xFF00 && code <= 0xFFEF);      // 全角字符
}

/**
 * 把一段文本切成"排版单元"
 *  - 空格：单独成元（断行位置）
 *  - CJK 字 / 全角标点 / emoji：各自成元（逐字可断）
 *  - 西文单词与数字：整词成元（避免把 "HarmonyOS" 劈成两半）
 */
function splitUnits(text: string): string[] {
  const out: string[] = [];
  let word: string = '';
  let i: number = 0;
  while (i < text.length) {
    const code: number = text.charCodeAt(i);
    // 代理对（emoji）：两码元整体成元，否则会被切成乱码
    if (isHighSurrogate(code) && i + 1 < text.length) {
      if (word.length > 0) {
        out.push(word);
        word = '';
      }
      out.push(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    const ch: string = text.charAt(i);
    if (ch === ' ') {
      if (word.length > 0) {
        out.push(word);
        word = '';
      }
      out.push(' ');
    } else if (isBreakableChar(code)) {
      if (word.length > 0) {
        out.push(word);
        word = '';
      }
      out.push(ch);
    } else {
      word += ch;
    }
    i += 1;
  }
  if (word.length > 0) {
    out.push(word);
  }
  return out;
}

/**
 * 文字排版：先按显式 \n 拆段，再在最大像素宽度内贪心折行
 *
 * 两个修正（此前实现的问题）：
 *  1. 按 UTF-16 码元逐字符切分会把 emoji 拆成两个乱码字符 → 改成先切"排版单元"；
 *  2. 西文长单词会被从中间硬劈开 → 优先回退到最近空格处断行。
 * 逐单元 measureText 无法避免（Canvas 没有"增量测宽"接口），
 * 但单元数已远少于字符数，且艺术字通常只有几十个单元。
 */
function layoutLines(content: string, maxWidthPx: number,
  ctx: OffscreenCanvasRenderingContext2D): string[] {
  const result: string[] = [];
  const paragraphs: string[] = content.split('\n');
  for (let pi = 0; pi < paragraphs.length; pi++) {
    const units: string[] = splitUnits(paragraphs[pi]);
    let line: string = '';
    // 最近一个空格在行内的字符下标（-1 = 本行还没有可回退位置）
    let lastSpace: number = -1;
    for (let i = 0; i < units.length; i++) {
      const u: string = units[i];
      const test: string = line + u;
      if (line.length > 0 && ctx.measureText(test).width > maxWidthPx) {
        if (lastSpace > 0) {
          // 回退到空格处断行，行首不留空格
          result.push(line.substring(0, lastSpace));
          line = line.substring(lastSpace + 1) + u;
        } else {
          result.push(line);
          line = u;
        }
        lastSpace = -1;
      } else {
        line = test;
      }
      if (u === ' ') {
        lastSpace = line.length - 1;
      }
    }
    result.push(line);
  }
  return result;
}

/**
 * 在底图上合成全部图层并输出 JPEG
 * @param base      当前编辑位图（滤镜/纹理/裁剪/旋转后的结果）
 * @param baseW     底图像素宽
 * @param baseH     底图像素高
 * @param texts     文字图层
 * @param stickers  贴纸图层（file:// URI）
 * @param disp      图片在预览区的显示矩形
 * @param previewW  预览区宽(vp)
 * @param previewH  预览区高(vp)
 * @param quality   JPEG 质量 1~100
 */
export async function composeToJpeg(base: image.PixelMap, baseW: number, baseH: number,
  texts: TextItem[], stickers: StickerItem[], disp: DispRect,
  previewW: number, previewH: number, quality: number): Promise<ArrayBuffer> {
  // 离屏画布尺寸 = 底图像素尺寸（构造只有 2 参，默认像素单位）
  const canvas: OffscreenCanvas = new OffscreenCanvas(baseW, baseH);
  const settings: RenderingContextSettings = new RenderingContextSettings(true);
  const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', settings);

  // 1. 底图铺满整张画布（画布尺寸 = 底图尺寸，无缩放无灰边）
  ctx.drawImage(base, 0, 0, baseW, baseH);

  // vp → 图片像素的换算比
  const k: number = 1 / disp.scale;
  const maxTextWidthPx: number = (previewW - TEXT_SIDE_GAP) * k;

  // 2. 文字层（多行 + 4 种风格）
  for (let ti = 0; ti < texts.length; ti++) {
    const t: TextItem = texts[ti];
    const anchor: LayerPoint = toAnchor(t.x, t.y, disp, previewW, previewH);
    const fontSizePx: number = TEXT_BASE_FONT * t.scale * k;
    // 字重必须与预览一致：预览用 FontWeight.Bold 渲染，
    // 导出若用常规字重，成品会比用户看到的细一圈（经典"所见非所得"）。
    ctx.font = `bold ${fontSizePx}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    const lines: string[] = layoutLines(t.content, maxTextWidthPx, ctx);
    const lineH: number = fontSizePx * LINE_HEIGHT;
    const firstY: number = anchor.y - ((lines.length - 1) * lineH) / 2;

    // 风格参数（与 UI 的 ShadowOptions 逐项对齐）
    // 注意：预览里的阴影半径/偏移是**固定 vp**（不随 t.scale 放大），
    // 因此这里也只乘 k（vp→像素），不再乘 t.scale —— 否则字号越大，导出阴影越大，与预览不符。
    ctx.fillStyle = toRgba(t.color, 1);
    ctx.strokeStyle = 'rgba(0,0,0,1)';
    // 描边：预览用 4 个 ±1vp 的零半径阴影近似轮廓，等效于 2vp 居中描边
    ctx.lineWidth = Math.max(1, 2 * k);
    if (t.style === 1) {
      // 预览：{ radius: 4, color: '#66000000', offsetX: 1, offsetY: 2 }
      ctx.shadowColor = 'rgba(0,0,0,0.4)';
      ctx.shadowBlur = 4 * k;
      ctx.shadowOffsetX = 1 * k;
      ctx.shadowOffsetY = 2 * k;
    } else if (t.style === 2) {
      // 预览：{ radius: 12, color: '#88FFFFFF', offsetX: 0, offsetY: 0 }
      ctx.shadowColor = 'rgba(255,255,255,0.53)';
      ctx.shadowBlur = 12 * k;
      ctx.shadowOffsetX = 0;
      ctx.shadowOffsetY = 0;
    }

    for (let li = 0; li < lines.length; li++) {
      const yy: number = firstY + li * lineH;
      if (t.style === 3) {
        ctx.strokeText(lines[li], anchor.x, yy);
      }
      ctx.fillText(lines[li], anchor.x, yy);
    }
    // 复位阴影，避免污染后续绘制
    ctx.shadowColor = 'rgba(0,0,0,0)';
    ctx.shadowBlur = 0;
    ctx.shadowOffsetX = 0;
    ctx.shadowOffsetY = 0;
  }

  // 3. 贴纸层（异步解码；单张贴纸失败不阻断整体导出）
  for (let si = 0; si < stickers.length; si++) {
    const s: StickerItem = stickers[si];
    let src: image.ImageSource | undefined = undefined;
    let spm: image.PixelMap | undefined = undefined;
    try {
      src = image.createImageSource(s.content);
      spm = await src.createPixelMap();
      const info = spm.getImageInfoSync();
      const box: number = STICKER_BOX * s.scale * k;
      const f: number = Math.min(box / info.size.width, box / info.size.height);
      const dw: number = info.size.width * f;
      const dh: number = info.size.height * f;
      const anchor: LayerPoint = toAnchor(s.x, s.y, disp, previewW, previewH);
      // 绕贴纸中心旋转后绘制：与预览的 .rotate({ angle: s.angle }) 一致
      ctx.save();
      ctx.translate(anchor.x, anchor.y);
      ctx.rotate(s.angle * Math.PI / 180);
      ctx.drawImage(spm, -dw / 2, -dh / 2, dw, dh);
      ctx.restore();
    } catch (e) {
      console.error(`compose sticker failed: ${JSON.stringify(e)}`);
    } finally {
      if (spm !== undefined) {
        spm.release();
      }
      if (src !== undefined) {
        try {
          src.release();
        } catch (e) {
          // 忽略释放异常
        }
      }
    }
  }

  // 4. 直接从离屏上下文捕获 PixelMap（不走 ImageBitmap）→ JPEG
  const outPm: image.PixelMap = ctx.getPixelMap(0, 0, baseW, baseH);
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const buf: ArrayBuffer = await packer.packing(outPm, {
      format: 'image/jpeg',
      quality: quality
    });
    return buf;
  } finally {
    outPm.release();
    packer.release();
  }
}

/**
 * 按画布（= 目标设备屏幕像素）合成导出 —— "铺满屏幕"保存的唯一出处
 *
 * 与 `composeToJpeg` 的区别：画布尺寸不再等于底图尺寸，而是手机屏幕尺寸；
 * 底图按 cover + 用户的缩放/平移铺满画布，**画布内看到的就是用户看到的**，
 * 因此存出来的图天然是手机屏幕比例，设成壁纸也不会被系统二次裁切。
 *
 * 与预览共用同一套几何（`ViewMath.drawRect`），不会再出现"预览一种构图、存下来另一种"。
 *
 * @param base     底图像素
 * @param baseW    底图宽
 * @param baseH    底图高
 * @param canvasW  画布宽（px，来自 CanvasSpec）
 * @param canvasH  画布高（px）
 * @param t        归一化变换（缩放 + 归一化平移；预览侧由 vp 位移换算而来）
 * @param quality  JPEG 质量 1~100
 */
export async function composeCoverToJpeg(base: image.PixelMap, baseW: number, baseH: number,
  canvasW: number, canvasH: number, t: ViewTransform, quality: number): Promise<ArrayBuffer> {
  const canvas: OffscreenCanvas = new OffscreenCanvas(canvasW, canvasH);
  const settings: RenderingContextSettings = new RenderingContextSettings(true);
  const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', settings);

  // 底图按 cover + 缩放/平移铺满画布（超出部分自然被画布裁掉 = 用户看到的取景）
  const d: Rect = ViewMath.drawRect(baseW, baseH, canvasW, canvasH, t);
  ctx.drawImage(base, d.x, d.y, d.width, d.height);

  const outPm: image.PixelMap = ctx.getPixelMap(0, 0, canvasW, canvasH);
  const packer: image.ImagePacker = image.createImagePacker();
  try {
    return await packer.packing(outPm, { format: 'image/jpeg', quality: quality });
  } finally {
    outPm.release();
    packer.release();
  }
}

// 裁剪合成 —— 把选区那块内容按源图密度取出来（"所见即所裁"的唯一出处）
//
// 做法：在离屏画布上按与 UI 完全相同的变换画一遍源图（含缩放、平移、旋转），
// 画布原点对齐到选区左上角，于是画布内容 = 用户框住的那一块。
//
// 为什么不用 PixelMap.crop(region)：
//  1. crop 只接受轴对齐矩形，用户一旦缩放过/旋转过就得自己算逆向映射；
//     上一版正是漏了"绕预览中心缩放"这一项，所以"框住的"和"裁出来的"不是一块；
//  2. 这里复用 cropDrawTransform()，正向/逆向同一套公式，且带单元测试。
//
// 返回的 PixelMap 所有权交给调用方（调用方负责 release）；canvasScale 是长边护栏
// 带来的额外缩放（4096 以内的常规图恒为 1），换算文字/贴纸锚点时要乘上它。
export async function composeCropToPixelMap(base: image.PixelMap, baseW: number, baseH: number,
  rect: CropRect, view: CropView, maxLongEdge: number): Promise<CropComposeResult> {
  const t: CropDrawTransform = cropDrawTransform(rect, view);
  const size: CropSize = cropOutputSize(rect, view);
  const limited: Size = ViewMath.limitLongEdge(size.width, size.height, maxLongEdge);
  const cap: number = size.width > 0 ? limited.width / size.width : 1;

  const canvas: OffscreenCanvas = new OffscreenCanvas(limited.width, limited.height);
  const settings: RenderingContextSettings = new RenderingContextSettings(true);
  const ctx: OffscreenCanvasRenderingContext2D = canvas.getContext('2d', settings);

  // 旋转时画布四角会露出底色，先铺黑，避免出现透明块
  ctx.fillStyle = 'rgba(0,0,0,1)';
  ctx.fillRect(0, 0, limited.width, limited.height);
  ctx.save();
  ctx.translate(t.tx * cap, t.ty * cap);
  ctx.rotate(t.radians);
  ctx.scale(t.scale * cap, t.scale * cap);
  ctx.drawImage(base, 0, 0, baseW, baseH);
  ctx.restore();

  const outPm: image.PixelMap = ctx.getPixelMap(0, 0, limited.width, limited.height);
  return { pixelMap: outPm, width: limited.width, height: limited.height, canvasScale: cap };
}
