import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import request from '@ohos.request';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { taskpool } from '@kit.ArkTS';
import { Wallpaper } from '../../model/Wallpaper';
import { runFilterTask, runTextureTask } from '../editor/FilterTask';
import { toggleFilter, toggleTexture, NO_FILTER, NO_TEXTURE } from '../editor/FilterPipeline';
import { TextItem, StickerItem, HandleBase, DispRect, CropRect } from '../editor/EditorModels';
import {
  BASE_FILTERS,
  STYLE_FILTERS,
  FILTERS,
  TEXTURES,
  TEXT_COLORS,
  TEXT_STYLES,
  THEME_PHRASES,
  QUOTE_PHRASES,
  FIT_MODE_CONTAIN
} from '../editor/EditorConstants';
import {
  calcCropRect,
  cropRatioValue,
  CropView,
  CropDrawTransform,
  cropDrawTransform,
  unprojectCrop
} from '../editor/CropGeometry';
import {
  toAnchor,
  fromAnchor,
  clampAnchor,
  mapRotate,
  mapFlip,
  LayerPoint
} from '../editor/LayerGeometry';
import { composeToJpeg, composeCropToPixelMap, CropComposeResult } from '../editor/ImageComposer';
import { PixelScope } from '../utils/PixelScope';
import { CanvasSpec } from '../canvas/CanvasSpec';
import { EditGuard } from '../utils/EditGuard';
import { EditorCanvasModel, ObservableCanvasState } from '../editor/EditorCanvasModel';
import { CanvasView } from './CanvasView';

/**
 * 位图副本（"让 Image 重绘"的唯一手段：换个 PixelMap 句柄，框架才会重新取图）
 *
 * 两个字段都要填（对照本机 SDK 的 `image.InitializationOptions`）：
 *  - `srcPixelFormat`：这段字节到底是什么格式（解码出来的可能是 BGRA_8888）；
 *  - `pixelFormat`：期望产出 RGBA_8888 —— 后面的滤镜（TaskPool 逐像素）与 Image 组件
 *    都按 RGBA 处理，统一格式既避免"旋转/翻转后掉色"，也避免把 BGRA 字节当 RGBA 去调色。
 * 参考实现：`limuyang2/ohos-Crop` 的 `copyPixelMap()`（MIT）。
 */
async function clonePixelMap(pm: image.PixelMap): Promise<image.PixelMap> {
  const info = pm.getImageInfoSync();
  const bytes: ArrayBuffer = new ArrayBuffer(pm.getPixelBytesNumber());
  await pm.readPixelsToBuffer(bytes);
  const opts: image.InitializationOptions = {
    size: { width: info.size.width, height: info.size.height },
    srcPixelFormat: info.pixelFormat,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: true
  };
  return image.createPixelMap(bytes, opts);
}

/**
 * ImageEditor —— DIY 图片编辑器（全屏，三页共用）
 *
 * 能力（官方 Image Kit 自研）：
 *  1. 旋转（±90°）/ 水平翻转 / 垂直翻转
 *  2. 裁剪：自由（四角拖拽缩放）+ 预设比例
 *  3. 滤镜：基础 13 款 + 风格化 7 款（水墨/油画/印象派/剪纸/乐高/金属/毛绒）
 *  4. 纹理叠加：纸纹/水彩纸纹/噪点/光晕/污渍 + 强度调节（可叠加在滤镜上）
 *  5. 艺术字：预置文案（主题文字/励志语录）+ 4 种文字风格 + 多行排版
 *  6. 文字：拖拽/缩放/换色/删除
 *  7. 导出：SaveButton 临时授权 + OffscreenCanvas 离屏合成（原分辨率、无灰边）→ JPEG 存相册
 */
@Component
export struct ImageEditor {
  /** 壁纸（取图片源） */
  @Prop wallpaper: Wallpaper = new Wallpaper();
  /** 本地兜底图（可选） */
  localImg: Resource | undefined = undefined;
  /** 关闭回调 */
  onClose: () => void = () => {
  };

  /**
   * 画布 + 图层状态（阶段 5 第 3d 步：唯一所有者）
   *
   * 此前这些状态（文字/贴纸数组、选中态、拖动实时标量、裁剪框、预览尺寸、底图尺寸）
   * 是二十来个 @State 直接摊在本组件里的；现在收敛成 `model.canvas` / `model.layers`，
   * 由 `CanvasView` 通过 @ObjectLink 读写，本组件只负责编排与导出。
   * 五条所有权规则见 RESTRUCTURE-PLAN.md「三之二」：不复制到本地 @State、
   * 拖动只写实时标量、位图单向流入、裁剪几何只走 CropGeometry。
   */
  @State model: EditorCanvasModel = new EditorCanvasModel();
  /**
   * 与 `model.canvas` 是**同一个实例**（aboutToAppear 里对齐，不是副本）。
   *
   * 为什么要多挂一次 @State：ArkUI V1 的观察是"按对象注册"的 —— 组件只会成为它自己
   * @State/@ObjectLink 的那个对象的订阅者（框架里由 ObservedObject.addOwningProperty 登记），
   * **嵌套对象的属性写入不会通知外层容器**。所以：
   *  - 本组件的渲染凡是要跟着 canvas 变（裁剪比例胶囊的高亮）就读 `this.canvas.*`；
   *  - 画布侧同理，CanvasView 用 @ObjectLink 直接订阅 canvas/layers。
   * 事件处理（写入）走哪个引用都一样，因为它们指向同一份数据。
   */
  @State canvas: ObservableCanvasState = new ObservableCanvasState();
  /** 当前编辑位图 */
  @State curPixelMap: image.PixelMap | undefined = undefined;
  /**
   * 位图资源作用域：curPixelMap 每次替换（旋转/裁剪/滤镜/纹理）都会产生新位图，
   * 旧位图必须释放，否则每操作一次泄漏一张全分辨率图（约 8MB/次）。
   */
  private scope: PixelScope = new PixelScope();
  /**
   * 底图（问题四：滤镜/纹理要"从底图重算"，而不是在当前位上层层叠加）
   *
   *  - `basePixelMap` = 底图：只烘焙几何（旋转/翻转/裁剪），**不含**滤镜/纹理；
   *  - `curPixelMap` = 显示/导出用的成品：底图 → 滤镜 → 纹理。
   *
   * 于是"同一个滤镜再点一次"= 清掉滤镜回到原图色，换滤镜也不会叠色。
   * 底图有独立的作用域：它不参与"当前显示位图"的替换，否则换滤镜时会把它顺手释放掉。
   * 代价是多一份全分辨率位图常驻（1080×1920 ≈ 8MB），这是非破坏式管线必须付的成本。
   */
  private baseScope: PixelScope = new PixelScope();
  private basePixelMap: image.PixelMap | undefined = undefined;
  /**
   * 是否有未保存的修改：旋转/翻转/裁剪/滤镜/纹理/文字/贴纸任一操作后置 true。
   * 关闭编辑器时据此弹出确认，避免返回手势一滑就丢掉全部创作。
   * 图层侧的增删改还会写进 `model.layers` 的 dirty 标记（见 layerDirty），两处取"或"。
   */
  private dirty: boolean = false;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;
  @State loading: boolean = true;
  @State saving: boolean = false;
  /** 滤镜/纹理后台处理中（TaskPool） */
  @State processing: boolean = false;

  /** 当前工具页 */
  @State tool: string = 'transform';
  /** 当前滤镜 */
  @State filterName: string = '原图';
  /** 当前纹理与强度 */
  @State textureName: string = '';
  @State textureStrength: number = 70;
  @State showTextInput: boolean = false;
  @State textInput: string = '';
  @State textColor: string = '#FFFFFF';
  @State textStyle: number = 0;
  /** 我的抠图贴纸（文件路径） */
  @State userStickers: string[] = [];

  /** 裁剪态图片拖拽基准 */
  private cropPanBaseX: number = 0;
  private cropPanBaseY: number = 0;
  /** 裁剪态双指缩放基准 */
  private cropPinchBase: number = 1;
  /** 裁剪框八把手拖拽起点（拖拽开始时从选区快照，几何仍走 CropGeometry.calcCropRect） */
  private handleBase: HandleBase = { x: 0, y: 0, w: 0, h: 0 };

  aboutToAppear(): void {
    // 让 canvas 指向 model 里的那个实例（同一份数据，不产生副本）
    this.canvas = this.model.canvas;
    this.cleanupStaleFiles();
    // 注册返回键处理：编辑器作为覆盖层，返回键应先问"是否放弃编辑"而不是直接关页面
    this.backId = EditGuard.push((): boolean => {
      this.requestClose();
      return true;
    });
    this.loadOriginal();
    this.loadUserStickers();
  }

  /**
   * 组件销毁（关闭编辑器）时必须释放位图。
   * 此前 ImageEditor 完全没有 aboutToDisappear，退出编辑器时当前全分辨率位图
   * 直接泄漏（1080×1920 RGBA ≈ 8MB/次），反复进出即 OOM。
   */
  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
    this.scope.dispose();
    this.baseScope.dispose();
  }

  /**
   * 请求关闭：有未保存修改时先确认
   * ✕ 按钮与系统返回键共用此入口，保证两条路径行为一致。
   */
  private async requestClose(): Promise<void> {
    // 两处 dirty 取"或"：位图类操作写 this.dirty，图层类操作写 LayerStore 的 dirty 标记
    if (!this.dirty && !this.model.layers.isDirty()) {
      this.onClose();
      return;
    }
    const discard: boolean = await EditGuard.confirmDiscard();
    if (discard) {
      this.onClose();
    }
  }

  /** 安全删除文件（文件不存在等异常不影响主流程） */
  private safeUnlink(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (e) {
      // 忽略：文件可能已被清理
    }
  }

  /** 清理历史编辑/导出/预览残留的临时文件，避免长期占用沙箱空间 */
  private cleanupStaleFiles(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      const names: string[] = fileIo.listFileSync(ctx.filesDir);
      for (const n of names) {
        // 前缀清单必须覆盖所有导出路径（含贴纸工作台/画板），否则残留文件会越堆越多
        if (n.startsWith('zeroone_edit_') || n.startsWith('zeroone_export_')
          || n.startsWith('zeroone_preview_') || n.startsWith('zeroone_wallpaper_')
          || n.startsWith('zeroone_board_')) {
          this.safeUnlink(`${ctx.filesDir}/${n}`);
        }
      }
    } catch (e) {
      console.error(`cleanupStaleFiles failed: ${JSON.stringify(e)}`);
    }
  }

  // ==================== 图片加载与位图操作 ====================

  async loadOriginal(): Promise<void> {
    this.loading = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      let data: ArrayBuffer;
      if (this.localImg !== undefined) {
        const content: Uint8Array = await ctx.resourceManager.getMediaContent(this.localImg);
        data = content.buffer as ArrayBuffer;
      } else {
        const dest: string = `${ctx.filesDir}/zeroone_edit_${Date.now()}.jpg`;
        const task: request.DownloadTask = await request.downloadFile(ctx, {
          'url': this.wallpaper.imageUrl,
          'filePath': dest
        });
        await new Promise<void>((resolve, reject) => {
          task.on('complete', () => {
            resolve();
          });
          task.on('fail', () => {
            reject(new Error('download failed'));
          });
        });
        const f = fileIo.openSync(dest, fileIo.OpenMode.READ_ONLY);
        const size: number = fileIo.statSync(dest).size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(f.fd, buf);
        fileIo.closeSync(f);
        data = buf;
        // 像素已读入内存，立即删除下载临时文件
        this.safeUnlink(dest);
      }
      const src: image.ImageSource = image.createImageSource(data);
      const pm: image.PixelMap = await src.createPixelMap({ editable: true });
      // 解码完成后 ImageSource 即无用武之地：PixelMap 持有自己的像素缓冲
      try {
        src.release();
      } catch (e) {
        console.error(`release ImageSource failed: ${JSON.stringify(e)}`);
      }
      const info = pm.getImageInfoSync();
      this.model.canvas.imageW = info.size.width;
      this.model.canvas.imageH = info.size.height;
      // 解码结果就是"几何基准"：滤镜/纹理都从它重算（重载即复位滤镜链）
      this.basePixelMap = this.baseScope.setCurrent(await this.toEditableRgba(pm));
      this.filterName = NO_FILTER;
      this.textureName = NO_TEXTURE;
      await this.refreshFromBase(false);
    } catch (e) {
      console.error(`loadOriginal failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '图片加载失败' });
    } finally {
      this.loading = false;
    }
  }

  /**
   * 从底图重新推导"显示位图"：底图 → 滤镜 → 纹理
   *
   * - 滤镜链为空时只做一份副本：Image 组件要换到新的 PixelMap 句柄才会重绘；
   * - 有滤镜/纹理时按顺序重跑（先滤镜后纹理，与旧行为一致），结果恒为 RGBA_8888；
   * - 所有"换滤镜/换纹理/旋转/翻转/裁剪"都走这里，保证画面永远等于"底图 + 当前滤镜链"。
   *
   * @param markEdit 是否算一次未保存修改（几何/滤镜操作 true；加载/重置 false）
   */
  private async refreshFromBase(markEdit: boolean): Promise<void> {
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    const w: number = this.model.canvas.imageW;
    const h: number = this.model.canvas.imageH;
    try {
      if (this.filterName === NO_FILTER && this.textureName === NO_TEXTURE) {
        this.curPixelMap = this.scope.setCurrent(await clonePixelMap(base));
      } else {
        this.processing = true;
        try {
          let bytes: ArrayBuffer = new ArrayBuffer(base.getPixelBytesNumber());
          await base.readPixelsToBuffer(bytes);
          if (this.filterName !== NO_FILTER) {
            const filtered: object = await taskpool.execute(runFilterTask, bytes, w, h, this.filterName);
            bytes = filtered as ArrayBuffer;
          }
          if (this.textureName !== NO_TEXTURE) {
            const textured: object = await taskpool.execute(runTextureTask, bytes, w, h,
              this.textureName, this.textureStrength);
            bytes = textured as ArrayBuffer;
          }
          // commitBytes 内部会 setCurrent + 标脏
          await this.commitBytes(bytes);
        } finally {
          this.processing = false;
        }
      }
      if (markEdit) {
        this.dirty = true;
      }
    } catch (e) {
      console.error(`refreshFromBase failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '图片处理失败，请重试' });
    }
  }

  /**
   * 把位图归一化成"可编辑的 RGBA_8888"
   *
   * 为什么要归一化：滤镜是 TaskPool 里的逐像素计算，它**按 RGBA 解释字节**；
   * 而解码出来的位图可能是 BGRA_8888 —— 直接喂给滤镜就会通道错位（掉色）。
   * 已经是 RGBA 时原样返回（不做多余拷贝）；发生转换时**原图会被释放**。
   */
  private async toEditableRgba(pm: image.PixelMap): Promise<image.PixelMap> {
    const info = pm.getImageInfoSync();
    if (info.pixelFormat === image.PixelMapFormat.RGBA_8888) {
      return pm;
    }
    const converted: image.PixelMap = await clonePixelMap(pm);
    PixelScope.safeRelease(pm);
    return converted;
  }

  /** 用处理后的字节生成新 PixelMap */
  private async commitBytes(bytes: ArrayBuffer): Promise<void> {
    const opts: image.InitializationOptions = {
      size: { width: this.model.canvas.imageW, height: this.model.canvas.imageH },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    };
    this.curPixelMap = this.scope.setCurrent(await image.createPixelMap(bytes, opts));
    // 滤镜/纹理都会走到这里 → 标记有未保存修改
    this.dirty = true;
  }

  async rotateImage(angle: number): Promise<void> {
    // 几何烘焙进**底图**，滤镜/纹理随后从底图重算（旋转不会丢滤镜，也不会叠色）
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    const dispOld: DispRect = this.dispRect();
    await base.rotate(angle);
    const tmp: number = this.model.canvas.imageW;
    this.model.canvas.imageW = this.model.canvas.imageH;
    this.model.canvas.imageH = tmp;
    // 文字/贴纸锚点随画面旋转（旋转后尺寸互换）
    this.remapOverlays((p: LayerPoint): LayerPoint => mapRotate(p, angle, oldW, oldH),
      dispOld, oldH, oldW);
    await this.refreshFromBase(true);
  }

  async flip(horizontal: boolean, vertical: boolean): Promise<void> {
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    const dispOld: DispRect = this.dispRect();
    await base.flip(horizontal, vertical);
    // 翻转不改尺寸，图层只做镜像
    this.remapOverlays((p: LayerPoint): LayerPoint => mapFlip(p, horizontal, vertical, oldW, oldH),
      dispOld, oldW, oldH);
    await this.refreshFromBase(true);
  }

  /**
   * 几何变换后重映射全部叠加图层（文字/贴纸）：
   * 变换前把 translate(vp) 换算成旧图像素锚点，经 map 映射到新图像素，再反算新 translate；
   * 图层缩放跟随画面放大量（新 scale / 旧 scale）。
   * 必须在 model.canvas.imageW/imageH 已更新为变换后尺寸时调用。
   */
  private remapOverlays(map: (p: LayerPoint) => LayerPoint, dispOld: DispRect,
    newW: number, newH: number): void {
    const cw: number = this.model.canvas.previewW;
    const ch: number = this.model.canvas.previewH;
    const dispNew: DispRect = this.dispRect();
    const ratio: number = dispOld.scale > 0 ? dispNew.scale / dispOld.scale : 1;
    const texts: TextItem[] = this.model.layers.texts();
    for (let i = 0; i < texts.length; i++) {
      const t: TextItem = texts[i];
      const a: LayerPoint = toAnchor(t.x, t.y, dispOld, cw, ch);
      const m: LayerPoint = clampAnchor(map(a), newW, newH);
      const p: LayerPoint = fromAnchor(m.x, m.y, dispNew, cw, ch);
      t.x = p.x;
      t.y = p.y;
      t.scale = t.scale * ratio;
    }
    const stickers: StickerItem[] = this.model.layers.stickers();
    for (let i = 0; i < stickers.length; i++) {
      const s: StickerItem = stickers[i];
      const a: LayerPoint = toAnchor(s.x, s.y, dispOld, cw, ch);
      const m: LayerPoint = clampAnchor(map(a), newW, newH);
      const p: LayerPoint = fromAnchor(m.x, m.y, dispNew, cw, ch);
      s.x = p.x;
      s.y = p.y;
      s.scale = s.scale * ratio;
    }
    // 批量几何重映射是就地改点的（不是拖动手势），改完标脏并推一次刷新
    this.model.layers.markDirty();
  }

  reset(): void {
    // 回到原图：清掉文字、复位滤镜/纹理/裁剪，并重新加载底图
    this.model.layers.clearTexts();
    // 重置后画面就是原图，图层侧的 dirty 跟着清掉（父组件的 dirty 保持原样，
    // 与旧行为一致：此前编辑过再点重置，关闭时仍会确认）
    this.model.layers.markClean();
    this.filterName = NO_FILTER;
    this.textureName = NO_TEXTURE;
    this.model.canvas.cropVisible = false;
    this.loadOriginal();
  }

  /** 裁剪专用重置：只重置裁剪参数，不影响滤镜/文字/贴纸 */
  resetCrop(): void {
    this.model.canvas.clearCrop();
  }

  /**
   * 切换画布适配档位。
   * 铺满是壁纸默认；完整显示用 contain，CanvasView 会补模糊底图。
   * 切换后立即刷新 disp；若正处于裁剪态，则按新的可视图片区域重建选区。
   */
  setFitMode(mode: string): void {
    if (this.model.canvas.fitMode === mode) {
      return;
    }
    this.model.canvas.fitMode = mode;
    this.dispRect();
    if (this.model.canvas.cropVisible) {
      this.selectCropRatio(this.model.canvas.cropRatio);
    }
    this.dirty = true;
  }

  // ==================== 裁剪 ====================
  // 裁剪手势由 CanvasView 回报位移（dx/dy/scale），几何一律留在这里：
  // 选区计算走 CropGeometry.calcCropRect，图片变换直接写 CanvasState —— 不出现第二套坐标换算。

  /** 裁剪态：拖动图片开始（记录基准） */
  private onCropDragStart(): void {
    this.cropPanBaseX = this.model.canvas.cropOffsetX;
    this.cropPanBaseY = this.model.canvas.cropOffsetY;
  }

  /** 裁剪态：拖动图片（苹果照片式：手指在选区内拖动图片，而非选区） */
  private onCropDragUpdate(dx: number, dy: number): void {
    this.model.canvas.cropOffsetX = this.cropPanBaseX + dx;
    this.model.canvas.cropOffsetY = this.cropPanBaseY + dy;
  }

  /** 裁剪态：双指缩放开始（记录基准） */
  private onCropPinchStart(): void {
    this.cropPinchBase = this.model.canvas.cropScale;
  }

  /** 裁剪态：双指缩放图片（0.5~5 倍，与旧行为一致） */
  private onCropPinchUpdate(scale: number): void {
    this.model.canvas.cropScale = Math.max(0.5, Math.min(5, this.cropPinchBase * scale));
  }

  /** 把手拖拽开始：把当前选区快照成基准（8 个把手共用） */
  private onCropHandleStart(): void {
    this.handleBase = {
      x: this.model.canvas.cropX,
      y: this.model.canvas.cropY,
      w: this.model.canvas.cropW,
      h: this.model.canvas.cropH
    };
  }

  /**
   * dispRect 缓存：入参（预览区尺寸 + 底图像素尺寸）没变就直接复用，
   * 避免单次交互里重复计算 8+ 次；入参一旦变化自动重算，无需外部记得调用失效。
   */
  private dispCache: DispRect = { x: 0, y: 0, w: 0, h: 0, scale: 1 };
  private dispKeyW: number = -1;
  private dispKeyH: number = -1;
  private dispKeyImageW: number = -1;
  private dispKeyImageH: number = -1;
  private dispKeyFit: string = '';

  private dispRect(): DispRect {
    const cw: number = this.model.canvas.previewW;
    const ch: number = this.model.canvas.previewH;
    const iw: number = this.model.canvas.imageW;
    const ih: number = this.model.canvas.imageH;
    const fitMode: string = this.model.canvas.fitMode;
    if (this.dispKeyW === cw && this.dispKeyH === ch
      && this.dispKeyImageW === iw && this.dispKeyImageH === ih
      && this.dispKeyFit === fitMode) {
      return this.dispCache;
    }
    let next: DispRect;
    if (iw <= 0 || ih <= 0 || cw <= 0 || ch <= 0) {
      next = { x: 0, y: 0, w: cw, h: ch, scale: 1 };
    } else if (fitMode === FIT_MODE_CONTAIN) {
      // 完整显示：短边贴齐，得到 letterbox 后的实际图片区域
      const scale: number = Math.min(cw / iw, ch / ih);
      const w: number = iw * scale;
      const h: number = ih * scale;
      next = { x: (cw - w) / 2, y: (ch - h) / 2, w: w, h: h, scale: scale };
    } else {
      // 铺满：长边贴齐，超出预览区的部分表示被 cover 裁掉
      const scale: number = Math.max(cw / iw, ch / ih);
      const w: number = iw * scale;
      const h: number = ih * scale;
      next = { x: (cw - w) / 2, y: (ch - h) / 2, w: w, h: h, scale: scale };
    }
    this.dispCache = next;
    this.dispKeyW = cw;
    this.dispKeyH = ch;
    this.dispKeyImageW = iw;
    this.dispKeyImageH = ih;
    this.dispKeyFit = fitMode;
    // 显示矩形是画布状态的一部分（裁剪换算要读它）：写回 model.canvas，不另存副本
    this.model.canvas.disp = next;
    return next;
  }

  /**
   * 裁剪选区可用的可视图片区域：disp 与预览区的交集。
   * contain 时就是 letterbox 后的图片区域；cover 时是预览可视区。
   * 但裁剪合成的坐标系仍使用完整 disp（见 cropView），保证源图密度正确。
   */
  private visibleDispRect(): DispRect {
    const disp: DispRect = this.dispRect();
    const left: number = Math.max(disp.x, 0);
    const top: number = Math.max(disp.y, 0);
    const right: number = Math.min(disp.x + disp.w, this.model.canvas.previewW);
    const bottom: number = Math.min(disp.y + disp.h, this.model.canvas.previewH);
    return {
      x: left,
      y: top,
      w: Math.max(0, right - left),
      h: Math.max(0, bottom - top),
      scale: disp.scale
    };
  }

  /**
   * 选择裁剪比例（苹果照片式）：
   * 在图片显示区域内取「该比例能容纳的最大窗口」，窗口可整体滑动
   * 支持比例：自由、1:1、4:3、3:4、16:9、9:16
   */
  selectCropRatio(ratio: string): void {
    this.model.canvas.cropRatio = ratio;
    const disp: DispRect = this.visibleDispRect();
    let w: number = disp.w;
    let h: number = disp.h;
    if (ratio !== '自由') {
      const target: number = cropRatioValue(ratio);
      // 最大可容纳的同比例窗口
      w = Math.min(disp.w, disp.h * target);
      h = w / target;
      if (h > disp.h) {
        h = disp.h;
        w = h * target;
      }
    }
    this.model.canvas.cropW = w;
    this.model.canvas.cropH = h;
    this.model.canvas.cropX = disp.x + (disp.w - w) / 2;
    this.model.canvas.cropY = disp.y + (disp.h - h) / 2;
    // 切比例时重置图片变换，避免上次状态残留导致选区错位
    this.model.canvas.resetCropTransform();
    this.model.canvas.cropVisible = true;
  }

  async applyCrop(): Promise<void> {
    // 裁的是**底图**（几何）：滤镜/纹理随后从新底图重算，效果不会丢
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined || !this.model.canvas.cropVisible) {
      return;
    }
    const dispOld: DispRect = this.dispRect();
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    // 选区与图片变换都取自 CanvasState（与 UI 使用的是同一份数据）
    const rect: CropRect = this.model.canvas.cropRect();
    const view: CropView = this.model.canvas.cropView();
    const t: CropDrawTransform = cropDrawTransform(rect, view);
    this.processing = true;
    try {
      // 与 UI 同一套变换在离屏画布上重绘 → 缩放/平移/旋转都被正确带进结果
      const res: CropComposeResult = await composeCropToPixelMap(base, oldW, oldH, rect, view,
        CanvasSpec.MAX_LONG_EDGE);
      this.model.canvas.imageW = res.width;
      this.model.canvas.imageH = res.height;
      // 裁剪产物来自离屏画布：归一化成可编辑的 RGBA 底图，后续旋转/翻转才能原地改
      this.basePixelMap = this.baseScope.setCurrent(await this.toEditableRgba(res.pixelMap));
      // 图层锚点重映射：旧图像素 → 屏幕(vp) → 输出画布像素 → 新图像素
      // （乘 canvasScale 抵消长边护栏带来的额外缩放）
      const dispNew: DispRect = this.dispRect();
      const toOutput: number = dispNew.scale > 0 ? 1 / (dispNew.scale * res.canvasScale) : 1;
      this.remapOverlays((p: LayerPoint): LayerPoint => {
        const sx: number = dispOld.x + p.x * dispOld.scale;
        const sy: number = dispOld.y + p.y * dispOld.scale;
        return unprojectCrop((sx - dispNew.x) * toOutput, (sy - dispNew.y) * toOutput, t);
      }, dispOld, this.model.canvas.imageW, this.model.canvas.imageH);
      // 提交后退出裁剪态并复位（选区、比例、图片变换）
      this.model.canvas.clearCrop();
      await this.refreshFromBase(true);
      promptAction.showToast({ message: '已裁剪 ✅' });
    } catch (e) {
      console.error(`applyCrop failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '裁剪失败，请重试' });
      this.model.canvas.cropVisible = false;
    } finally {
      this.processing = false;
    }
  }
  /**
   * 四角/四边把手拖拽：几何计算在 CropGeometry.calcCropRect 纯函数中，
   * type 0=左上 1=右上 2=左下 3=右下 4=上边 5=右边 6=下边 7=左边（对边固定，固定比例联动宽高）
   */
  private onCropHandleDrag(type: number, dx: number, dy: number): void {
    const rect: CropRect = calcCropRect(this.handleBase, type, dx, dy,
      this.visibleDispRect(), cropRatioValue(this.model.canvas.cropRatio));
    this.model.canvas.cropX = rect.x;
    this.model.canvas.cropY = rect.y;
    this.model.canvas.cropW = rect.w;
    this.model.canvas.cropH = rect.h;
  }

  // ==================== 滤镜 ====================

  /**
   * 应用滤镜：从**底图**重算（问题四），逐像素计算放到 TaskPool 工作线程，
   * 只跨线程传 ArrayBuffer，不传 PixelMap；处理中显示遮罩并屏蔽重复点击。
   *
   * 再点一次当前滤镜 = 取消（回到原图色）；换一个滤镜 = 换掉，不叠色。
   */
  async applyFilter(name: string): Promise<void> {
    if (name === NO_FILTER) {
      // 恢复原图：重新解码文件（几何/滤镜/纹理一起复位，与旧行为一致）
      this.filterName = NO_FILTER;
      this.textureName = NO_TEXTURE;
      // 若之前裁剪过，重载会改变底图尺寸，图层锚点按比例回射到新底图
      const oldW: number = this.model.canvas.imageW;
      const oldH: number = this.model.canvas.imageH;
      const dispOld: DispRect = this.dispRect();
      await this.loadOriginal();
      if (oldW > 0 && oldH > 0
        && (oldW !== this.model.canvas.imageW || oldH !== this.model.canvas.imageH)) {
        const sx: number = this.model.canvas.imageW / oldW;
        const sy: number = this.model.canvas.imageH / oldH;
        this.remapOverlays((p: LayerPoint): LayerPoint => {
          return { x: p.x * sx, y: p.y * sy };
        }, dispOld, this.model.canvas.imageW, this.model.canvas.imageH);
      }
      return;
    }
    if (this.processing) {
      return;
    }
    if (this.basePixelMap === undefined) {
      return;
    }
    // 再点一次当前滤镜 = 取消（回原图色），换一个 = 换掉，不叠色
    this.filterName = toggleFilter(this.filterName, name);
    await this.refreshFromBase(true);
  }

  // ==================== 纹理叠加 ====================

  /**
   * 应用纹理：同样从底图重算 —— 管线是"底图 → 滤镜 → 纹理"，强度取 textureStrength。
   * 再点一次当前纹理 = 取消。
   */
  async applyTexture(name: string): Promise<void> {
    if (name === '') {
      return;
    }
    if (this.processing) {
      return;
    }
    if (this.basePixelMap === undefined) {
      return;
    }
    this.textureName = toggleTexture(this.textureName, name);
    await this.refreshFromBase(true);
  }

  // ==================== 文字与艺术字 ====================

  /** 添加文字（支持多行 \n） */
  addText(content?: string): void {
    const text: string = (content !== undefined ? content : this.textInput).trim();
    if (text.length === 0) {
      promptAction.showToast({ message: '请输入文字' });
      return;
    }
    // 级联偏移：避免连续添加的文字全部重叠在画面正中心
    const cascade: number = this.model.layers.textCount() % 4;
    const item: TextItem = {
      content: text,
      color: this.textColor,
      x: cascade * 16 - 24,
      y: -70 + cascade * 16,
      scale: 1,
      style: this.textStyle
    };
    // LayerStore.addText 会顺带选中新图层并标脏
    this.model.layers.addText(item);
    this.textInput = '';
    this.showTextInput = false;
    this.dirty = true;
  }

  /** 添加预置文案 */
  addPhrase(phrase: string): void {
    this.addText(phrase);
  }

  removeText(idx: number): void {
    // 删除后的选中态由 LayerStore 修正（删的是选中项 → 取消选中；删的是它前面的项 → 下标前移）
    this.model.layers.removeText(idx);
    this.dirty = true;
  }

  // ==================== 贴纸 ====================

  /** 加载我的抠图贴纸（应用贴纸目录下的 PNG） */
  loadUserStickers(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const dir: string = `${ctx.filesDir}/stickers`;
    const list: string[] = [];
    try {
      if (fileIo.accessSync(dir)) {
        const names: string[] = fileIo.listFileSync(dir);
        for (const n of names) {
          if (n.endsWith('.png')) {
            list.push(`file://${dir}/${n}`);
          }
        }
      }
    } catch (e) {
      console.error(`loadUserStickers failed: ${JSON.stringify(e)}`);
    }
    this.userStickers = list;
  }

  /** 添加贴纸到画布（content 为 file:// 路径或相册临时 URI） */
  private pushSticker(content: string): void {
    const item: StickerItem = { content: content, x: 0, y: 0, scale: 1, angle: 0 };
    // LayerStore.addSticker 会顺带选中新图层并标脏
    this.model.layers.addSticker(item);
    this.dirty = true;
  }

  /** 添加抠图 PNG 贴纸 */
  addPngSticker(path: string): void {
    this.pushSticker(path);
  }

  /**
   * 把相册选中的图片复制进沙盒再当贴纸用
   *
   * 为什么必须复制：PhotoViewPicker 返回的是 `file://media/...` URI，读取授权是**临时**的，
   * 一旦授权失效，Image 加载不到内容，节点在真机上退化成一块透明区域——表现就是
   * "导入的贴纸完全拖不动、也缩放不了"，而内置贴纸因为本来就是沙盒文件所以不受影响。
   * 复制进沙盒后两者走完全同一条路径，顺带解决"重启后贴纸变空白"。
   * 复制失败时回退原 URI，不阻塞用户操作。
   */
  private copyStickerIntoFiles(uri: string): string {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const dir: string = `${ctx.filesDir}/stickers`;
      try {
        fileIo.mkdirSync(dir, true);
      } catch (e) {
        // 目录已存在（或创建失败）时继续，后续 openSync 会给出真实结果
      }
      const dest: string = `${dir}/imported_${Date.now()}.png`;
      const out = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.copyFileSync(uri, out.fd);
      } finally {
        fileIo.closeSync(out);
      }
      return `file://${dest}`;
    } catch (e) {
      console.error(`copyStickerIntoFiles failed, fallback to uri: ${JSON.stringify(e)}`);
      return uri;
    }
  }

  /** 从相册选择 PNG/图片贴纸添加到画布（PhotoViewPicker 无需权限） */
  async pickStickerFromAlbum(): Promise<void> {
    try {
      const p: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const res: picker.PhotoSelectResult = await p.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (res.photoUris !== undefined && res.photoUris.length > 0) {
        // 先落盘到沙盒再当贴纸：相册 URI 的授权是临时的，直接用会导致贴纸拖不动/缩放不了
        this.addPngSticker(this.copyStickerIntoFiles(res.photoUris[0]));
      }
    } catch (e) {
      console.error(`pickStickerFromAlbum failed: ${JSON.stringify(e)}`);
    }
  }

  /** 删除贴纸 */
  removeSticker(idx: number): void {
    // 删除后的选中态由 LayerStore 修正（与文字同规则）
    this.model.layers.removeSticker(idx);
    this.dirty = true;
  }

  /** 切换文字风格（有选中文字则改选中项，否则作为新文字的默认） */
  setTextStyle(style: number): void {
    this.textStyle = style;
    const idx: number = this.model.layers.selectedText();
    if (idx >= 0) {
      this.model.layers.setTextStyle(idx, style);
      this.dirty = true;
    }
  }

  /**
   * 选中态滑杆相对本体的纵向位置（vp）
   * 本体尺寸随 scale 变化，滑杆要始终贴在本体下方，不能压住它
   */
  private sliderOffsetFor(baseSize: number, scale: number): number {
    return (baseSize * scale) / 2 + 40;
  }

  // ==================== 导出 ====================

  async exportAndSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.processing) {
      promptAction.showToast({ message: '图片处理中，请稍候' });
      return;
    }
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    this.saving = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let dest: string = '';
    try {
      this.model.canvas.cropVisible = false;
      // 离屏合成：底图原分辨率 + 文字 + 贴纸，不截屏幕（无灰边、无选中态红钮、不被降采样）
      const buf: ArrayBuffer = await composeToJpeg(pm, this.model.canvas.imageW, this.model.canvas.imageH,
        this.model.layers.texts(), this.model.layers.stickers(), this.dispRect(),
        this.model.canvas.previewW, this.model.canvas.previewH, 92);
      dest = `${ctx.filesDir}/zeroone_export_${Date.now()}.jpg`;
      const file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const f2 = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
      fileIo.copyFileSync(dest, f2.fd);
      fileIo.closeSync(f2);
      promptAction.showToast({ message: '已保存到相册 📷' });
      // 已导出成功：编辑成果已进相册，关闭时无需再提示"放弃编辑"
      this.dirty = false;
      this.model.layers.markClean();
    } catch (e) {
      console.error(`export failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '保存失败，请重试' });
    } finally {
      // 无论成功失败都清理沙箱临时文件
      if (dest.length > 0) {
        this.safeUnlink(dest);
      }
      this.saving = false;
    }
  }

  // ==================== UI ====================

  @Builder
  toolChip(label: string, key: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.tool === key ? Color.White : '#666666')
      .backgroundColor(this.tool === key ? '#FF6B6B' : '#F0F0F0')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => {
        this.tool = key;
        if (key === 'crop' && !this.model.canvas.cropVisible) {
          this.selectCropRatio('自由');
        }
      })
  }

  @Builder
  opButton(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor('#333333')
      .backgroundColor('#FFFFFF')
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(12)
      .shadow({ radius: 2, color: '#16000000', offsetY: 1 })
      .onClick(() => {
        action();
      })
  }

  build() {
    Stack() {
      if (this.loading) {
        LoadingProgress()
          .width(60)
          .height(60)
          .color('#FF6B6B')
      } else {
        Column() {
          // ===== 顶部栏 =====
          Row() {
            Text('✕')
              .fontSize(20)
              .fontColor('#333333')
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                // 统一走 requestClose：有未保存修改会先确认
                this.requestClose();
              })
            // 保存中：在标题位显示进度，让用户知道在等什么（此前点了无任何反馈）
            if (this.saving) {
              Row({ space: 6 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color('#FF6B6B')
                Text('正在保存…')
                  .fontSize(13)
                  .fontColor('#9A9AA5')
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
            } else {
              Text('图片编辑')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#333333')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
            }
            SaveButton({ text: SaveDescription.SAVE, buttonType: ButtonType.Capsule })
              .height(36)
              // 保存中禁用：防止连点产生多张重复相册图
              // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
              .enabled(!this.saving)
              .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                if (result === SaveButtonOnClickResult.SUCCESS) {
                  this.exportAndSave();
                }
              })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 6 })

          // ===== 预览区（画布渲染与手势已搬进 CanvasView；处理遮罩留在编排层） =====
          Stack() {
            // 画布：预览 Stack + 文字/贴纸图层 + 全部手势都在 CanvasView 里，
            // 状态（画布 + 图层）唯一所有者仍是本组件：两个对象通过 @ObjectLink 传入
            // （ArkUI V1 的 @ObjectLink 必须挂在真正被改的对象上，挂容器观察不到嵌套属性）
            CanvasView({
              state: this.model.canvas,
              layers: this.model.layers,
              pixelMap: this.curPixelMap,
              tool: this.tool,
              // 滑杆纵向偏移是纯函数（见 sliderOffsetFor），传给画布避免两边各写一份换算
              offsetForSlider: (baseSize: number, scale: number): number => this.sliderOffsetFor(baseSize, scale),
              // 回调：画布只回报"选中/删除/数据变了/裁剪手势位移"，状态改动仍由本组件执行
              onSelectText: (idx: number): void => {
                this.model.layers.selectText(idx);
              },
              onSelectSticker: (idx: number): void => {
                this.model.layers.selectSticker(idx);
              },
              onRemoveText: (idx: number): void => {
                this.removeText(idx);
              },
              onRemoveSticker: (idx: number): void => {
                this.removeSticker(idx);
              },
              onLayersChanged: (): void => {
                this.dirty = true;
              },
              onFitModeChanged: (mode: string): void => {
                this.setFitMode(mode);
              },
              onCropDragStart: (): void => {
                this.onCropDragStart();
              },
              onCropDragUpdate: (dx: number, dy: number): void => {
                this.onCropDragUpdate(dx, dy);
              },
              onCropPinchStart: (): void => {
                this.onCropPinchStart();
              },
              onCropPinchUpdate: (scale: number): void => {
                this.onCropPinchUpdate(scale);
              },
              onCropHandleStart: (): void => {
                this.onCropHandleStart();
              },
              onCropHandleDrag: (type: number, dx: number, dy: number): void => {
                this.onCropHandleDrag(type, dx, dy);
              }
            })

            // ===== 后台处理遮罩（滤镜/纹理 TaskPool 执行期间，盖在预览最上层） =====
            if (this.processing) {
              Column() {
                LoadingProgress()
                  .width(44)
                  .height(44)
                  .color(Color.White)
                Text('处理中…')
                  .fontSize(12)
                  .fontColor(Color.White)
                  .margin({ top: 8 })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor('#88000000')
            }
          }
          .id('editorRoot')
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#EEEEEE')
          .onAreaChange((oldValue: Area, newValue: Area) => {
            // 预览区尺寸是画布状态的一部分（裁剪换算要读它）：写进 model.canvas，不做副本
            this.model.canvas.previewW = newValue.width as number;
            this.model.canvas.previewH = newValue.height as number;
            // 预览区尺寸变化后立即重算 disp，图层夹紧与裁剪边界才能拿到最新矩形
            this.dispRect();
          })

          // ===== 工具 tab（横向滚动，防止 chip 被截断） =====
          Scroll() {
            Row({ space: 8 }) {
              this.toolChip('旋转/翻转', 'transform')
              this.toolChip('裁剪', 'crop')
              this.toolChip('滤镜', 'filter')
              this.toolChip('纹理', 'texture')
              this.toolChip('文字', 'text')
              this.toolChip('贴纸', 'sticker')
            }
            .padding({ top: 8, bottom: 6 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

          // ===== 工具面板 =====
          Column({ space: 8 }) {
            if (this.tool === 'transform') {
              Row({ space: 10 }) {
                this.opButton('↺ 左转', () => {
                  // 逆时针 90°：写 270 而不是 -90（官方文档只写"角度"，没约定负角语义）
                  this.rotateImage(270);
                })
                this.opButton('↻ 右转', () => {
                  this.rotateImage(90);
                })
                this.opButton('⇋ 水平翻转', () => {
                  this.flip(true, false);
                })
                this.opButton('⇌ 垂直翻转', () => {
                  this.flip(false, true);
                })
                this.opButton('↩ 重置', () => {
                  this.reset();
                })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            } else if (this.tool === 'crop') {
              Column({ space: 10 }) {
                // 裁剪比例（苹果照片式：自由、1:1、4:3、3:4、16:9、9:16）
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(['自由', '1:1', '4:3', '3:4', '16:9', '9:16'], (r: string) => {
                      Text(r)
                        .fontSize(13)
                        // 读走 this.canvas.*：本组件是 canvas 的订阅者，这里才会跟着重绘
                        .fontColor(this.canvas.cropVisible && this.canvas.cropRatio === r
                          ? Color.White : '#555555')
                        .backgroundColor(this.canvas.cropVisible && this.canvas.cropRatio === r
                          ? '#FF6B6B' : Color.White)
                        .border({
                          width: 1,
                          color: this.canvas.cropVisible && this.canvas.cropRatio === r
                            ? '#FF6B6B' : '#DDDDDD'
                        })
                        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                        .borderRadius(16)
                        .onClick(() => {
                          this.selectCropRatio(r);
                        })
                    })
                  }
                  .padding({ left: 8, right: 8 })
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')

                // 旋转/镜像操作行（苹果照片式：在裁剪界面内操作）
                Row({ space: 10 }) {
                  this.opButton('↺ 左转', () => {
                    // 同 transform 面板：逆时针 90° 用 270 表达
                    this.rotateImage(270);
                  })
                  this.opButton('↻ 右转', () => {
                    this.rotateImage(90);
                  })
                  this.opButton('⇌ 水平', () => {
                    this.flip(true, false);
                  })
                  this.opButton('⇍ 垂直', () => {
                    this.flip(false, true);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                // 操作按钮：重置（裁剪专用）、取消、应用
                Row({ space: 14 }) {
                  Text('重置')
                    .fontSize(13)
                    .fontColor('#666666')
                    .backgroundColor('#F2F2F2')
                    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                    .borderRadius(18)
                    .onClick(() => {
                      this.resetCrop();
                    })
                  Text('取消')
                    .fontSize(13)
                    .fontColor('#666666')
                    .backgroundColor('#F2F2F2')
                    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                    .borderRadius(18)
                    .onClick(() => {
                      // 退出裁剪态并复位（选区、比例、图片变换）
                      this.model.canvas.clearCrop();
                    })
                  Text('✓ 应用')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .backgroundColor('#FF6B6B')
                    .padding({ left: 24, right: 24, top: 8, bottom: 8 })
                    .borderRadius(18)
                    .shadow({ radius: 4, color: '#33FF6B6B', offsetY: 1 })
                    .onClick(() => {
                      this.applyCrop();
                    })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)

                Text('拖动选区调整大小，拖动图片调整位置，双指缩放')
                  .fontSize(11)
                  .fontColor('#AAAAAA')
              }
              .width('100%')
              .padding({ top: 2, bottom: 2 })
            } else if (this.tool === 'filter') {
              Scroll() {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    ForEach(BASE_FILTERS, (f: string) => {
                      Text(f)
                        .fontSize(13)
                        .fontColor(this.filterName === f ? Color.White : '#666666')
                        .backgroundColor(this.filterName === f ? '#FF6B6B' : '#F0F0F0')
                        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                        .borderRadius(12)
                        .onClick(() => {
                          this.applyFilter(f);
                        })
                    })
                  }
                  Row({ space: 8 }) {
                    ForEach(STYLE_FILTERS, (f: string) => {
                      Text(f)
                        .fontSize(13)
                        .fontColor(this.filterName === f ? Color.White : '#AA66FF')
                        .backgroundColor(this.filterName === f ? '#AA66FF' : '#F3EDFF')
                        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                        .borderRadius(12)
                        .onClick(() => {
                          this.applyFilter(f);
                        })
                    })
                  }
                }
                .padding({ left: 12, right: 12 })
              }
              .scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .height(110)
            } else if (this.tool === 'texture') {
              Column({ space: 8 }) {
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(TEXTURES, (t: string) => {
                      Text(t)
                        .fontSize(13)
                        .fontColor(this.textureName === t ? Color.White : '#666666')
                        .backgroundColor(this.textureName === t ? '#FF6B6B' : '#F0F0F0')
                        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                        .borderRadius(12)
                        .onClick(() => {
                          this.applyTexture(t);
                        })
                    })
                  }
                  .padding({ left: 12, right: 12 })
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')

                Row({ space: 10 }) {
                  Text('强度')
                    .fontSize(12)
                    .fontColor('#999999')
                  Slider({ value: this.textureStrength, min: 10, max: 100, step: 5 })
                    .width('50%')
                    .selectedColor('#FF6B6B')
                    .onChange((v: number, mode: SliderChangeMode) => {
                      this.textureStrength = v;
                      // 松手才重跑纹理：拖动中每帧跑一次 TaskPool 太贵（且管线是从底图重算的）
                      if (mode === SliderChangeMode.End && this.textureName !== '' && !this.processing) {
                        this.refreshFromBase(true);
                      }
                    })
                  Text(`${this.textureStrength}%`)
                    .fontSize(12)
                    .fontColor('#666666')
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
              }
            } else if (this.tool === 'text') {
              Scroll() {
                Column({ space: 8 }) {
                  if (!this.showTextInput) {
                    Row({ space: 10 }) {
                      this.opButton('✍️ 自定义文字', () => {
                        this.showTextInput = true;
                      })
                      this.opButton('清除全部', () => {
                        this.model.layers.clearTexts();
                        this.dirty = true;
                      })
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                  } else {
                    Column({ space: 8 }) {
                      TextArea({ placeholder: '输入文字（可换行）', text: this.textInput })
                        .fontSize(14)
                        .height(70)
                        .onChange((v: string) => {
                          this.textInput = v;
                        })
                      Row({ space: 8 }) {
                        ForEach(TEXT_COLORS, (c: string) => {
                          Circle({ width: 24, height: 24 })
                            .fill(c)
                            .border({ width: this.textColor === c ? 2 : 0, color: '#FF6B6B' })
                            .onClick(() => {
                              this.textColor = c;
                              // 已有选中文字时立即换色（与风格按钮行为一致），否则只作为新文字默认色
                              const idx: number = this.model.layers.selectedText();
                              if (idx >= 0) {
                                this.model.layers.setTextColor(idx, c);
                                this.dirty = true;
                              }
                            })
                        })
                      }
                      Row({ space: 10 }) {
                        this.opButton('确定', () => {
                          this.addText();
                        })
                        this.opButton('取消', () => {
                          this.showTextInput = false;
                        })
                      }
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                  }

                  // 文字风格
                  Row({ space: 8 }) {
                    ForEach(TEXT_STYLES, (s: string, idx: number) => {
                      Text(s)
                        .fontSize(12)
                        .fontColor(this.textStyle === idx ? Color.White : '#666666')
                        .backgroundColor(this.textStyle === idx ? '#FF6B6B' : '#F0F0F0')
                        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                        .borderRadius(10)
                        .onClick(() => {
                          this.setTextStyle(idx);
                        })
                    })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)

                  // 主题文字预置
                  Text('主题文字')
                    .fontSize(12)
                    .fontColor('#999999')
                    .width('100%')
                    .padding({ left: 12 })
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(THEME_PHRASES, (p: string) => {
                      Text(p)
                        .fontSize(12)
                        .fontColor('#FF6B6B')
                        .backgroundColor('#FFF0F1')
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .borderRadius(10)
                        .margin({ right: 8, bottom: 8 })
                        .onClick(() => {
                          this.addPhrase(p);
                        })
                    })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12 })

                  // 励志语录预置
                  Text('励志语录')
                    .fontSize(12)
                    .fontColor('#999999')
                    .width('100%')
                    .padding({ left: 12 })
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(QUOTE_PHRASES, (p: string) => {
                      Text(p)
                        .fontSize(12)
                        .fontColor('#666666')
                        .backgroundColor('#F5F5F5')
                        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                        .borderRadius(10)
                        .margin({ right: 8, bottom: 8 })
                        .onClick(() => {
                          this.addPhrase(p);
                        })
                    })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, bottom: 6 })
                }
                .width('100%')
              }
              .scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .height(150)
            } else if (this.tool === 'sticker') {
              Scroll() {
                Column({ space: 12 }) {
                  // 我的抠图贴纸
                  Text('我的抠图贴纸（点击添加到画面）')
                    .fontSize(12)
                    .fontColor('#999999')
                    .width('100%')
                    .padding({ left: 12, top: 4 })
                  if (this.userStickers.length === 0) {
                    Text('还没有贴纸，点下方「相册选贴纸」添加一张吧 �')
                      .fontSize(12)
                      .fontColor('#BBBBBB')
                      .width('100%')
                      .padding({ left: 12, right: 12 })
                  } else {
                    Flex({ wrap: FlexWrap.Wrap }) {
                      ForEach(this.userStickers, (p: string) => {
                        Image(p)
                          .width(56)
                          .height(56)
                          .objectFit(ImageFit.Contain)
                          .backgroundColor('#F7F7F7')
                          .border({ width: 1, color: '#EEEEEE' })
                          .borderRadius(12)
                          .padding(4)
                          .margin({ right: 8, bottom: 8 })
                          .onClick(() => {
                            this.addPngSticker(p);
                          })
                      })
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                  }

                  // 操作入口
                  Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
                    this.opButton('🖼 相册选贴纸', () => {
                      this.pickStickerFromAlbum();
                    })
                    this.opButton('🗑 清除贴纸', () => {
                      this.model.layers.clearStickers();
                      this.dirty = true;
                    })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, bottom: 8 })

                  Text('小贴士：推荐使用透明背景 PNG；贴纸可拖动、双指缩放、双指旋转')
                    .fontSize(11)
                    .fontColor('#AAAAAA')
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                }
                .width('100%')
              }
              .scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .height(200)
            }
          }
          .width('100%')
          .padding({ bottom: 10 })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }
}
