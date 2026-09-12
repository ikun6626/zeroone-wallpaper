import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import request from '@ohos.request';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { taskpool } from '@kit.ArkTS';
import { Wallpaper } from '../../model/Wallpaper';
import { runFilterTask, runTextureTask } from '../editor/FilterTask';
import { TextItem, StickerItem, HandleBase, DispRect, CropRect } from '../editor/EditorModels';
import {
  BASE_FILTERS,
  STYLE_FILTERS,
  FILTERS,
  TEXTURES,
  TEXT_COLORS,
  TEXT_STYLES,
  THEME_PHRASES,
  QUOTE_PHRASES
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

  /** 当前编辑位图 */
  @State curPixelMap: image.PixelMap | undefined = undefined;
  /**
   * 位图资源作用域：curPixelMap 每次替换（旋转/裁剪/滤镜/纹理）都会产生新位图，
   * 旧位图必须释放，否则每操作一次泄漏一张全分辨率图（约 8MB/次）。
   */
  private scope: PixelScope = new PixelScope();
  /**
   * 是否有未保存的修改：旋转/翻转/裁剪/滤镜/纹理/文字/贴纸任一操作后置 true。
   * 关闭编辑器时据此弹出确认，避免返回手势一滑就丢掉全部创作。
   */
  private dirty: boolean = false;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;
  @State curW: number = 0;
  @State curH: number = 0;
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
  /** 文字列表 */
  @State texts: TextItem[] = [];
  @State selectedText: number = -1;
  /**
   * 文字拖动中的实时位移（不写回数组，避免每帧重建整个图层列表）
   * 拖动中只改这三个标量，松手时才把最终值提交进 texts 并刷新一次。
   */
  @State textDragIdx: number = -1;
  @State textDragDx: number = 0;
  @State textDragDy: number = 0;
  @State showTextInput: boolean = false;
  @State textInput: string = '';
  @State textColor: string = '#FFFFFF';
  @State textStyle: number = 0;
  /** 贴纸列表 */
  @State stickers: StickerItem[] = [];
  @State selectedSticker: number = -1;
  /** 我的抠图贴纸（文件路径） */
  @State userStickers: string[] = [];

  /** 裁剪框（容器坐标） */
  @State cropRatio: string = '自由';
  @State cropVisible: boolean = false;
  @State cropX: number = 0;
  @State cropY: number = 0;
  @State cropW: number = 0;
  @State cropH: number = 0;
  @State previewW: number = 360;
  @State previewH: number = 640;
  /** 裁剪态图片平移（拖动图片调整裁剪位置） */
  @State cropOffsetX: number = 0;
  @State cropOffsetY: number = 0;
  /** 裁剪态图片缩放 */
  @State cropScale: number = 1;
  /** 裁剪态任意角度旋转（度） */
  @State cropAngle: number = 0;

  /** 手势基准 */
  private textBaseX: number = 0;
  private textBaseY: number = 0;
  private textBaseScale: number = 1;
  /** 贴纸旋转手势基准角（度） */
  private stickerBaseAngle: number = 0;
  private handleBase: HandleBase = { x: 0, y: 0, w: 0, h: 0 };
  /** 裁剪态图片拖拽基准 */
  private cropPanBaseX: number = 0;
  private cropPanBaseY: number = 0;
  /** 裁剪态双指缩放基准 */
  private cropPinchBase: number = 1;

  aboutToAppear(): void {
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
  }

  /**
   * 请求关闭：有未保存修改时先确认
   * ✕ 按钮与系统返回键共用此入口，保证两条路径行为一致。
   */
  private async requestClose(): Promise<void> {
    if (!this.dirty) {
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
      this.curW = info.size.width;
      this.curH = info.size.height;
      this.invalidateDisp();
      this.curPixelMap = this.scope.setCurrent(pm);
    } catch (e) {
      console.error(`loadOriginal failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '图片加载失败' });
    } finally {
      this.loading = false;
    }
  }

  /** 操作后克隆位图（触发 Image 刷新）—— 保留原像素格式，避免旋转/翻转后通道错位掉色 */
  private async refreshPixelMap(): Promise<void> {
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    // 从位图本身读取真实像素格式（可能是 BGRA_8888 等），重建时保留，不硬编码 RGBA
    const info = pm.getImageInfoSync();
    const bytes: ArrayBuffer = new ArrayBuffer(pm.getPixelBytesNumber());
    await pm.readPixelsToBuffer(bytes);
    const opts: image.InitializationOptions = {
      size: { width: info.size.width, height: info.size.height },
      pixelFormat: info.pixelFormat,
      editable: true
    };
    // 旧图交给作用域延迟释放（Image 组件可能还在用旧句柄绘制）
    this.curPixelMap = this.scope.setCurrent(await image.createPixelMap(bytes, opts));
    // 旋转/翻转/裁剪都会走到这里 → 标记有未保存修改
    this.dirty = true;
  }

  /** 用处理后的字节生成新 PixelMap */
  private async commitBytes(bytes: ArrayBuffer): Promise<void> {
    const opts: image.InitializationOptions = {
      size: { width: this.curW, height: this.curH },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    };
    this.curPixelMap = this.scope.setCurrent(await image.createPixelMap(bytes, opts));
    // 滤镜/纹理都会走到这里 → 标记有未保存修改
    this.dirty = true;
  }

  async rotateImage(angle: number): Promise<void> {
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    const oldW: number = this.curW;
    const oldH: number = this.curH;
    const dispOld: DispRect = this.dispRect();
    await pm.rotate(angle);
    const tmp: number = this.curW;
    this.curW = this.curH;
    this.curH = tmp;
    this.invalidateDisp();
    // 文字/贴纸锚点随画面旋转（旋转后尺寸互换）
    this.remapOverlays((p: LayerPoint): LayerPoint => mapRotate(p, angle, oldW, oldH),
      dispOld, oldH, oldW);
    await this.refreshPixelMap();
  }

  async flip(horizontal: boolean, vertical: boolean): Promise<void> {
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    const oldW: number = this.curW;
    const oldH: number = this.curH;
    const dispOld: DispRect = this.dispRect();
    await pm.flip(horizontal, vertical);
    // 翻转不改尺寸，图层只做镜像
    this.remapOverlays((p: LayerPoint): LayerPoint => mapFlip(p, horizontal, vertical, oldW, oldH),
      dispOld, oldW, oldH);
    await this.refreshPixelMap();
  }

  /**
   * 几何变换后重映射全部叠加图层（文字/贴纸）：
   * 变换前把 translate(vp) 换算成旧图像素锚点，经 map 映射到新图像素，再反算新 translate；
   * 图层缩放跟随画面放大量（新 scale / 旧 scale）。
   * 必须在 curW/curH 已更新为变换后尺寸时调用。
   */
  private remapOverlays(map: (p: LayerPoint) => LayerPoint, dispOld: DispRect,
    newW: number, newH: number): void {
    const dispNew: DispRect = this.dispRect();
    const ratio: number = dispOld.scale > 0 ? dispNew.scale / dispOld.scale : 1;
    for (let i = 0; i < this.texts.length; i++) {
      const t: TextItem = this.texts[i];
      const a: LayerPoint = toAnchor(t.x, t.y, dispOld, this.previewW, this.previewH);
      const m: LayerPoint = clampAnchor(map(a), newW, newH);
      const p: LayerPoint = fromAnchor(m.x, m.y, dispNew, this.previewW, this.previewH);
      t.x = p.x;
      t.y = p.y;
      t.scale = t.scale * ratio;
    }
    for (let i = 0; i < this.stickers.length; i++) {
      const s: StickerItem = this.stickers[i];
      const a: LayerPoint = toAnchor(s.x, s.y, dispOld, this.previewW, this.previewH);
      const m: LayerPoint = clampAnchor(map(a), newW, newH);
      const p: LayerPoint = fromAnchor(m.x, m.y, dispNew, this.previewW, this.previewH);
      s.x = p.x;
      s.y = p.y;
      s.scale = s.scale * ratio;
    }
    this.refreshTexts();
    this.refreshStickers();
  }

  reset(): void {
    this.texts = [];
    this.selectedText = -1;
    this.filterName = '原图';
    this.textureName = '';
    this.cropVisible = false;
    this.loadOriginal();
  }

  /** 裁剪专用重置：只重置裁剪参数，不影响滤镜/文字/贴纸 */
  resetCrop(): void {
    this.cropRatio = '自由';
    this.cropVisible = false;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropScale = 1;
    this.cropAngle = 0;
  }

  /** 裁剪态：拖动图片（苹果照片式：手指在选区内拖动图片，而非选区） */
  onCropImageDrag(e: GestureEvent): void {
    this.cropOffsetX = this.cropPanBaseX + e.offsetX;
    this.cropOffsetY = this.cropPanBaseY + e.offsetY;
  }

  /** 裁剪态：双指缩放图片 */
  onCropImagePinch(e: GestureEvent): void {
    this.cropScale = Math.max(0.5, Math.min(5, this.cropPinchBase * e.scale));
  }

  // ==================== 裁剪 ====================

  /** dispRect 缓存（避免单次渲染中重复计算 8+ 次） */
  private dispCache: DispRect = { x: 0, y: 0, w: 0, h: 0, scale: 1 };
  private dispDirty: boolean = true;

  private dispRect(): DispRect {
    if (!this.dispDirty) {
      return this.dispCache;
    }
    const cw: number = this.previewW;
    const ch: number = this.previewH;
    if (this.curW <= 0 || this.curH <= 0 || cw <= 0 || ch <= 0) {
      this.dispCache = { x: 0, y: 0, w: cw, h: ch, scale: 1 };
      this.dispDirty = false;
      return this.dispCache;
    }
    const scale: number = Math.min(cw / this.curW, ch / this.curH);
    const w: number = this.curW * scale;
    const h: number = this.curH * scale;
    this.dispCache = { x: (cw - w) / 2, y: (ch - h) / 2, w: w, h: h, scale: scale };
    this.dispDirty = false;
    return this.dispCache;
  }

  /** 标记 dispRect 缓存失效（在 curW/curH/previewW/previewH 变化时调用） */
  private invalidateDisp(): void {
    this.dispDirty = true;
  }

  /**
   * 选择裁剪比例（苹果照片式）：
   * 在图片显示区域内取「该比例能容纳的最大窗口」，窗口可整体滑动
   * 支持比例：自由、1:1、4:3、3:4、16:9、9:16
   */
  selectCropRatio(ratio: string): void {
    this.cropRatio = ratio;
    const disp = this.dispRect();
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
    this.cropW = w;
    this.cropH = h;
    this.cropX = disp.x + (disp.w - w) / 2;
    this.cropY = disp.y + (disp.h - h) / 2;
    // 切比例时重置图片变换，避免上次状态残留导致选区错位
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropScale = 1;
    this.cropAngle = 0;
    this.cropVisible = true;
  }

  async applyCrop(): Promise<void> {
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined || !this.cropVisible) {
      return;
    }
    const dispOld: DispRect = this.dispRect();
    const oldW: number = this.curW;
    const oldH: number = this.curH;
    const rect: CropRect = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
    const view: CropView = {
      disp: dispOld,
      previewW: this.previewW,
      previewH: this.previewH,
      scale: this.cropScale,
      offsetX: this.cropOffsetX,
      offsetY: this.cropOffsetY,
      angle: this.cropAngle
    };
    const t: CropDrawTransform = cropDrawTransform(rect, view);
    this.processing = true;
    try {
      // 与 UI 同一套变换在离屏画布上重绘 → 缩放/平移/旋转都被正确带进结果
      const res: CropComposeResult = await composeCropToPixelMap(pm, oldW, oldH, rect, view,
        CanvasSpec.MAX_LONG_EDGE);
      this.curW = res.width;
      this.curH = res.height;
      this.curPixelMap = this.scope.setCurrent(res.pixelMap);
      this.invalidateDisp();
      // 图层锚点重映射：旧图像素 → 屏幕(vp) → 输出画布像素 → 新图像素
      // （乘 canvasScale 抵消长边护栏带来的额外缩放）
      const dispNew: DispRect = this.dispRect();
      const toOutput: number = dispNew.scale > 0 ? 1 / (dispNew.scale * res.canvasScale) : 1;
      this.remapOverlays((p: LayerPoint): LayerPoint => {
        const sx: number = dispOld.x + p.x * dispOld.scale;
        const sy: number = dispOld.y + p.y * dispOld.scale;
        return unprojectCrop((sx - dispNew.x) * toOutput, (sy - dispNew.y) * toOutput, t);
      }, dispOld, this.curW, this.curH);
      this.cropVisible = false;
      this.cropRatio = '自由';
      this.cropOffsetX = 0;
      this.cropOffsetY = 0;
      this.cropScale = 1;
      this.cropAngle = 0;
      await this.refreshPixelMap();
      promptAction.showToast({ message: '已裁剪 ✅' });
    } catch (e) {
      console.error(`applyCrop failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '裁剪失败，请重试' });
      this.cropVisible = false;
    } finally {
      this.processing = false;
    }
  }
  /**
   * 四角手柄拖拽：几何计算在 CropGeometry.calcCropRect 纯函数中，
   * type 0=左上 1=右上 2=左下 3=右下（对边固定，固定比例联动宽高）
   */
  private onCropHandleDrag(type: number, e: GestureEvent): void {
    const rect = calcCropRect(this.handleBase, type, e.offsetX, e.offsetY,
      this.dispRect(), cropRatioValue(this.cropRatio));
    this.cropX = rect.x;
    this.cropY = rect.y;
    this.cropW = rect.w;
    this.cropH = rect.h;
  }

  // ==================== 滤镜 ====================

  /**
   * 应用滤镜：逐像素计算放到 TaskPool 工作线程（FilterTask.runFilterTask），
   * 只跨线程传 ArrayBuffer，不传 PixelMap；处理中显示遮罩并屏蔽重复点击。
   */
  async applyFilter(name: string): Promise<void> {
    if (name === '原图') {
      // 恢复原图后同步复位滤镜/纹理选中态（像素被重载，旧效果已不存在）
      this.filterName = '原图';
      this.textureName = '';
      // 若之前裁剪过，重载会改变底图尺寸，图层锚点按比例回射到新底图
      const oldW: number = this.curW;
      const oldH: number = this.curH;
      const dispOld: DispRect = this.dispRect();
      await this.loadOriginal();
      if (oldW > 0 && oldH > 0 && (oldW !== this.curW || oldH !== this.curH)) {
        const sx: number = this.curW / oldW;
        const sy: number = this.curH / oldH;
        this.remapOverlays((p: LayerPoint): LayerPoint => {
          return { x: p.x * sx, y: p.y * sy };
        }, dispOld, this.curW, this.curH);
      }
      return;
    }
    if (this.processing) {
      return;
    }
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    try {
      this.processing = true;
      const bytes: ArrayBuffer = new ArrayBuffer(pm.getPixelBytesNumber());
      await pm.readPixelsToBuffer(bytes);
      const result: object = await taskpool.execute(runFilterTask, bytes, this.curW, this.curH, name);
      await this.commitBytes(result as ArrayBuffer);
      this.filterName = name;
    } catch (e) {
      console.error(`applyFilter failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '滤镜处理失败，请重试' });
    } finally {
      this.processing = false;
    }
  }

  // ==================== 纹理叠加 ====================

  /**
   * 应用纹理：逐像素计算放到 TaskPool 工作线程（FilterTask.runTextureTask）。
   * 纹理叠加在当前位图（已含滤镜）上，强度取 textureStrength。
   */
  async applyTexture(name: string): Promise<void> {
    if (name === '') {
      return;
    }
    if (this.processing) {
      return;
    }
    const pm: image.PixelMap | undefined = this.curPixelMap;
    if (pm === undefined) {
      return;
    }
    try {
      this.processing = true;
      const bytes: ArrayBuffer = new ArrayBuffer(pm.getPixelBytesNumber());
      await pm.readPixelsToBuffer(bytes);
      const result: object = await taskpool.execute(runTextureTask, bytes, this.curW, this.curH,
        name, this.textureStrength);
      await this.commitBytes(result as ArrayBuffer);
      this.textureName = name;
    } catch (e) {
      console.error(`applyTexture failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '纹理处理失败，请重试' });
    } finally {
      this.processing = false;
    }
  }

  // ==================== 文字与艺术字 ====================

  private refreshTexts(): void {
    const list: TextItem[] = [];
    for (const t of this.texts) {
      list.push(t);
    }
    this.texts = list;
    this.dirty = true;
  }

  /** 添加文字（支持多行 \n） */
  addText(content?: string): void {
    const text: string = (content !== undefined ? content : this.textInput).trim();
    if (text.length === 0) {
      promptAction.showToast({ message: '请输入文字' });
      return;
    }
    // 级联偏移：避免连续添加的文字全部重叠在画面正中心
    const cascade: number = this.texts.length % 4;
    const item: TextItem = {
      content: text,
      color: this.textColor,
      x: cascade * 16 - 24,
      y: -70 + cascade * 16,
      scale: 1,
      style: this.textStyle
    };
    const list: TextItem[] = [];
    for (const t of this.texts) {
      list.push(t);
    }
    list.push(item);
    this.texts = list;
    this.selectedText = this.texts.length - 1;
    this.textInput = '';
    this.showTextInput = false;
    this.dirty = true;
  }

  /** 添加预置文案 */
  addPhrase(phrase: string): void {
    this.addText(phrase);
  }

  removeText(idx: number): void {
    const list: TextItem[] = [];
    for (let i = 0; i < this.texts.length; i++) {
      if (i !== idx) {
        list.push(this.texts[i]);
      }
    }
    this.texts = list;
    this.selectedText = -1;
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
    const list: StickerItem[] = [];
    for (const s of this.stickers) {
      list.push(s);
    }
    list.push(item);
    this.stickers = list;
    this.selectedSticker = this.stickers.length - 1;
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
    const list: StickerItem[] = [];
    for (let i = 0; i < this.stickers.length; i++) {
      if (i !== idx) {
        list.push(this.stickers[i]);
      }
    }
    this.stickers = list;
    this.selectedSticker = -1;
    this.dirty = true;
  }

  /** 重建贴纸数组（触发刷新） */
  private refreshStickers(): void {
    const list: StickerItem[] = [];
    for (const s of this.stickers) {
      list.push(s);
    }
    this.stickers = list;
    this.dirty = true;
  }

  /** 切换文字风格（有选中文字则改选中项，否则作为默认） */
  setTextStyle(style: number): void {
    this.textStyle = style;
    if (this.selectedText >= 0 && this.selectedText < this.texts.length) {
      const t: TextItem = this.texts[this.selectedText];
      t.style = style;
      this.refreshTexts();
    }
  }

  /**
   * 选中态滑杆相对本体的纵向位置（vp）
   * 本体尺寸随 scale 变化，滑杆要始终贴在本体下方，不能压住它
   */
  private sliderOffsetFor(baseSize: number, scale: number): number {
    return (baseSize * scale) / 2 + 40;
  }

  /** 文字阴影（按风格） */
  private textShadowFor(t: TextItem): ShadowOptions | ShadowOptions[] {
    if (t.style === 1) {
      const s1: ShadowOptions = { radius: 4, color: '#66000000', offsetX: 1, offsetY: 2 };
      return s1;
    }
    if (t.style === 2) {
      const s2: ShadowOptions = { radius: 12, color: '#88FFFFFF', offsetX: 0, offsetY: 0 };
      return s2;
    }
    if (t.style === 3) {
      const s3: ShadowOptions[] = [
        { radius: 0, color: '#000000', offsetX: 1, offsetY: 0 },
        { radius: 0, color: '#000000', offsetX: -1, offsetY: 0 },
        { radius: 0, color: '#000000', offsetX: 0, offsetY: 1 },
        { radius: 0, color: '#000000', offsetX: 0, offsetY: -1 }
      ];
      return s3;
    }
    const s0: ShadowOptions = { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
    return s0;
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
      this.cropVisible = false;
      // 离屏合成：底图原分辨率 + 文字 + 贴纸，不截屏幕（无灰边、无选中态红钮、不被降采样）
      const buf: ArrayBuffer = await composeToJpeg(pm, this.curW, this.curH,
        this.texts, this.stickers, this.dispRect(), this.previewW, this.previewH, 92);
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
        if (key === 'crop' && !this.cropVisible) {
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

  /** 选区外压暗条（纯视觉，不拦截触摸） */
  @Builder
  cropDim(x: number, y: number, w: number, h: number) {
    Column()
      .width(w)
      .height(h)
      .backgroundColor('#73000000')
      .position({ x: x, y: y })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 文字图层渲染（阶段 5 第 3a 步：从 build() 里**原样搬出来**的 @Builder）
   *
   * 只搬家，逻辑与视觉一行未改。搬出来之后 build() 只剩"编排"，
   * 下一步 3c 会把它连同贴纸层一起搬进 CanvasView 组件。
   */
  @Builder
  textLayer(t: TextItem, idx: number) {
    // 外层 Column：文字内容在上，选中态的缩放滑块在下，整体随 translate 移动
    Column({ space: 4 }) {
      Stack() {
        Text(t.content)
          // 显式用 vp：fontSize 传数字时默认单位是 fp（会跟随系统字体大小设置缩放），
          // 而导出按 vp→像素换算。用户把系统字体调大后，
          // 预览会变大、导出却不变 —— 这就是"所见非所得"。写死 vp 后两侧一致。
          .fontSize(`${22 * t.scale}vp`)
          .fontColor(t.color)
          .fontWeight(FontWeight.Bold)
          .textShadow(this.textShadowFor(t))
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 44, maxWidth: this.previewW - 48 })
        if (this.selectedText === idx) {
          Text('✕')
            .fontSize(14)
            .fontColor(Color.White)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FF6B6B')
            .borderRadius(11)
            .offset({ x: 8, y: -8 })
            .onClick(() => {
              this.removeText(idx);
            })
        }
      }
      .alignContent(Alignment.TopEnd)
      // 选中态加虚线边框，提示可操作区域；未选中无视觉干扰
      .border(this.selectedText === idx ? { width: 1, color: '#FF6B6B', style: BorderStyle.Dashed } : { width: 0 })
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    }
    // Block：强制拦截触摸，全透明背景不再穿透到下层 Image
    .hitTestBehavior(HitTestMode.Block)
    .backgroundColor(Color.Transparent)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    // 拖动中叠加实时位移：只改标量，ForEach 不会重建整个列表
    .translate({
      x: t.x + (this.textDragIdx === idx ? this.textDragDx : 0),
      y: t.y + (this.textDragIdx === idx ? this.textDragDy : 0)
    })
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.selectedText = idx;
          this.textBaseX = t.x;
          this.textBaseY = t.y;
          this.textDragIdx = idx;
          this.textDragDx = 0;
          this.textDragDy = 0;
        })
        .onActionUpdate((e: GestureEvent) => {
          const limitX: number = this.previewW / 2 + 60;
          const limitY: number = this.previewH / 2 + 60;
          // 拖动中只更新实时增量：此前是"改 t.x/t.y → refreshTexts()"，
          // 而 refreshTexts 会换掉数组引用，于是每一帧都重建全部文字节点。
          this.textDragDx = Math.max(-limitX - this.textBaseX,
            Math.min(limitX - this.textBaseX, e.offsetX));
          this.textDragDy = Math.max(-limitY - this.textBaseY,
            Math.min(limitY - this.textBaseY, e.offsetY));
        })
        .onActionEnd(() => {
          // 松手才提交一次，并复位实时位移
          t.x = this.textBaseX + this.textDragDx;
          t.y = this.textBaseY + this.textDragDy;
          this.textDragIdx = -1;
          this.textDragDx = 0;
          this.textDragDy = 0;
          this.refreshTexts();
        })
    )
    .parallelGesture(
      PinchGesture()
        .onActionStart(() => {
          this.textBaseScale = t.scale;
        })
        .onActionUpdate((e: GestureEvent) => {
          t.scale = Math.max(0.5, Math.min(4, this.textBaseScale * e.scale));
          this.refreshTexts();
        })
    )

    // 选中态滑杆：与文字本体同级的兄弟节点 → 只影响自身，不会挪动本体
    if (this.selectedText === idx) {
      Row({ space: 4 }) {
        Text('A').fontSize(10).fontColor('#999999')
        Slider({ value: t.scale, min: 0.5, max: 4, step: 0.1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .blockColor('#FF6B6B')
          .selectedColor('#FF6B6B')
          .trackColor('#E0E0E0')
          .onChange((val: number) => {
            t.scale = val;
            this.refreshTexts();
          })
        Text('A').fontSize(18).fontColor('#FF6B6B').fontWeight(FontWeight.Bold)
      }
      .width(150)
      .translate({ x: t.x, y: t.y + this.sliderOffsetFor(22, t.scale) })
    }
  }

  /**
   * 贴纸图层渲染（阶段 5 第 3b 步：从 build() 里**原样搬出来**的 @Builder）
   *
   * 与 textLayer 同理：只搬家不改逻辑。搬运期间 ImageEditor 始终可编译、可回滚。
   */
  @Builder
  stickerLayer(s: StickerItem, idx: number) {
    Column({ space: 4 }) {
      Stack() {
        Image(s.content)
          .width(130 * s.scale)
          .height(130 * s.scale)
          .objectFit(ImageFit.Contain)
          // 贴纸自身旋转（与工作台/画板一致的 双指旋转 能力）
          .rotate({ angle: s.angle })
        if (this.selectedSticker === idx) {
          Text('✕')
            .fontSize(14)
            .fontColor(Color.White)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FF6B6B')
            .borderRadius(11)
            .position({ x: 90 * s.scale, y: -10 })
            .onClick(() => {
              this.removeSticker(idx);
            })
        }
      }
      // 选中态虚线边框
      .border(this.selectedSticker === idx ? { width: 1, color: '#FF6B6B', style: BorderStyle.Dashed } : { width: 0 })

      // 选中态控件（大小 + 旋转）同样作为**兄弟节点**渲染（见下方），
      // 放进本体里会把本体撑高，导致选中时位置与导出位置不一致。
    }
    .hitTestBehavior(HitTestMode.Block)
    .backgroundColor(Color.Transparent)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .translate({ x: s.x, y: s.y })
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.selectedSticker = idx;
          this.textBaseX = s.x;
          this.textBaseY = s.y;
        })
        .onActionUpdate((e: GestureEvent) => {
          const half: number = 65 * s.scale;
          const bx: number = Math.max(20, this.previewW / 2 - half);
          const by: number = Math.max(20, this.previewH / 2 - half);
          const nx: number = this.textBaseX + e.offsetX;
          const ny: number = this.textBaseY + e.offsetY;
          s.x = Math.max(-bx, Math.min(bx, nx));
          s.y = Math.max(-by, Math.min(by, ny));
          this.refreshStickers();
        })
    )
    .parallelGesture(
      PinchGesture()
        .onActionStart(() => {
          this.textBaseScale = s.scale;
        })
        .onActionUpdate((e: GestureEvent) => {
          s.scale = Math.max(0.4, Math.min(5, this.textBaseScale * e.scale));
          this.refreshStickers();
        })
    )
    .parallelGesture(
      // 双指旋转贴纸：此前编辑器贴纸根本转不了（工作台/画板都能转，体验割裂）
      RotationGesture()
        .onActionStart(() => {
          this.selectedSticker = idx;
          this.stickerBaseAngle = s.angle;
        })
        .onActionUpdate((e: GestureEvent) => {
          // 基准角 + 手势角（用累加会对不上手指，这是之前文字拖动踩过的坑）
          let next: number = this.stickerBaseAngle + e.angle;
          // 归一化到 (-180, 180]，避免角度无限增大
          while (next > 180) {
            next -= 360;
          }
          while (next <= -180) {
            next += 360;
          }
          s.angle = next;
          this.refreshStickers();
        })
    )

    // 选中态控件（兄弟节点）：大小 + 旋转，精确可控且不影响本体位置
    if (this.selectedSticker === idx) {
      Column({ space: 2 }) {
        Row({ space: 4 }) {
          Text('□').fontSize(10).fontColor('#999999')
          Slider({ value: s.scale, min: 0.4, max: 5, step: 0.1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .blockColor('#FF6B6B')
            .selectedColor('#FF6B6B')
            .trackColor('#E0E0E0')
            .onChange((val: number) => {
              s.scale = val;
              this.refreshStickers();
            })
          Text('□').fontSize(18).fontColor('#FF6B6B').fontWeight(FontWeight.Bold)
        }
        Row({ space: 4 }) {
          Text('⟳').fontSize(12).fontColor('#999999')
          Slider({ value: s.angle, min: -180, max: 180, step: 1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .blockColor('#FF6B6B')
            .selectedColor('#FF6B6B')
            .trackColor('#E0E0E0')
            .onChange((val: number) => {
              s.angle = val;
              this.refreshStickers();
            })
          Text('⟳').fontSize(16).fontColor('#FF6B6B').fontWeight(FontWeight.Bold)
        }
      }
      .width(170)
      .translate({ x: s.x, y: s.y + this.sliderOffsetFor(130, s.scale) })
    }
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

          // ===== 预览区 =====
          Stack() {
            // 裁剪态：图片在选区内可拖动/缩放，选区外不可见（苹果照片式）
            if (this.tool === 'crop' && this.cropVisible && this.curPixelMap !== undefined) {
              // 选区内 clip 容器：只有这个区域内的图片可见
              // 图片可拖动/缩放（苹果照片式：手指在选区内拖动图片，选区框固定不动）
              Stack() {
                // 内层容器 = 整个预览区的坐标系：图片在这里按 Contain 适配（与 dispRect 一致），
                // 再整体反向平移，选区之外的部分由外层 clip 裁掉。
                // 此前图片是直接按"选区尺寸"适配的 —— 选区一变图片就自己跳，
                // 而且与裁剪换算对不上，这正是"框住的"和"裁出来的"不是一块的根因之一。
                Stack() {
                  Image(this.curPixelMap)
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Contain)
                    .translate({ x: this.cropOffsetX, y: this.cropOffsetY })
                    .scale({ x: this.cropScale, y: this.cropScale })
                    .rotate({ angle: this.cropAngle })
                    .gesture(
                      PanGesture()
                        .onActionStart(() => {
                          this.cropPanBaseX = this.cropOffsetX;
                          this.cropPanBaseY = this.cropOffsetY;
                        })
                        .onActionUpdate((e: GestureEvent) => {
                          this.onCropImageDrag(e);
                        })
                    )
                    .parallelGesture(
                      PinchGesture()
                        .onActionStart(() => {
                          this.cropPinchBase = this.cropScale;
                        })
                        .onActionUpdate((e: GestureEvent) => {
                          this.onCropImagePinch(e);
                        })
                    )
                }
                .width(this.previewW)
                .height(this.previewH)
                .position({ x: -this.cropX, y: -this.cropY })
              }
              .width(this.cropW)
              .height(this.cropH)
              .position({ x: this.cropX, y: this.cropY })
              .clip(true)

              // 暗色遮罩：选区外完全不透明（盖住图片溢出部分）
              if (this.cropY > 0) {
                this.cropDim(0, 0, this.previewW, this.cropY)
              }
              if (this.cropY + this.cropH < this.previewH) {
                this.cropDim(0, this.cropY + this.cropH, this.previewW, this.previewH - this.cropY - this.cropH)
              }
              if (this.cropX > 0) {
                this.cropDim(0, this.cropY, this.cropX, this.cropH)
              }
              if (this.cropX + this.cropW < this.previewW) {
                this.cropDim(this.cropX + this.cropW, this.cropY, this.previewW - this.cropX - this.cropW, this.cropH)
              }

              // 选区框：白色细边框（苹果风格），纯视觉层
              // hitTestBehavior(None) 让触摸穿透到下层图片，由图片处理拖动
              // 选区框位置只能通过比例选择和把手拖拽改变（苹果照片式）
              Column()
                .width(this.cropW)
                .height(this.cropH)
                .border({ width: 1.5, color: Color.White })
                .backgroundColor(Color.Transparent)
                .position({ x: this.cropX, y: this.cropY })
                .hitTestBehavior(HitTestMode.None)

              // 四角把手：白色 L 型（苹果风格），内联以响应状态更新
              // 左上角
              Stack() {
                Column().width(20).height(3).backgroundColor(Color.White).position({ x: 0, y: 0 })
                Column().width(3).height(20).backgroundColor(Color.White).position({ x: 0, y: 0 })
              }
              .width(20)
              .height(20)
              .position({ x: this.cropX - 2, y: this.cropY - 2 })
              .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
              .gesture(
                PanGesture()
                  .onActionStart(() => {
                    this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropHandleDrag(0, e);
                  })
              )
              // 右上角
              Stack() {
                Column().width(20).height(3).backgroundColor(Color.White).position({ x: 0, y: 0 })
                Column().width(3).height(20).backgroundColor(Color.White).position({ x: 17, y: 0 })
              }
              .width(20)
              .height(20)
              .position({ x: this.cropX + this.cropW - 18, y: this.cropY - 2 })
              .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
              .gesture(
                PanGesture()
                  .onActionStart(() => {
                    this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropHandleDrag(1, e);
                  })
              )
              // 左下角
              Stack() {
                Column().width(20).height(3).backgroundColor(Color.White).position({ x: 0, y: 17 })
                Column().width(3).height(20).backgroundColor(Color.White).position({ x: 0, y: 0 })
              }
              .width(20)
              .height(20)
              .position({ x: this.cropX - 2, y: this.cropY + this.cropH - 18 })
              .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
              .gesture(
                PanGesture()
                  .onActionStart(() => {
                    this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropHandleDrag(2, e);
                  })
              )
              // 右下角
              Stack() {
                Column().width(20).height(3).backgroundColor(Color.White).position({ x: 0, y: 17 })
                Column().width(3).height(20).backgroundColor(Color.White).position({ x: 17, y: 0 })
              }
              .width(20)
              .height(20)
              .position({ x: this.cropX + this.cropW - 18, y: this.cropY + this.cropH - 18 })
              .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
              .gesture(
                PanGesture()
                  .onActionStart(() => {
                    this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropHandleDrag(3, e);
                  })
              )

              // 四边把手：白色细条（苹果风格），内联以响应状态更新
              // 上边中点
              Column()
                .width(30).height(3).borderRadius(1.5).backgroundColor(Color.White)
                .position({ x: this.cropX + this.cropW / 2 - 15, y: this.cropY - 2 })
                .responseRegion({ x: -18, y: -14, width: 66, height: 31 })
                .gesture(
                  PanGesture()
                    .onActionStart(() => {
                      this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                    })
                    .onActionUpdate((e: GestureEvent) => {
                      this.onCropHandleDrag(4, e);
                    })
                )
              // 右边中点
              Column()
                .width(3).height(30).borderRadius(1.5).backgroundColor(Color.White)
                .position({ x: this.cropX + this.cropW - 2, y: this.cropY + this.cropH / 2 - 15 })
                .responseRegion({ x: -14, y: -18, width: 31, height: 66 })
                .gesture(
                  PanGesture()
                    .onActionStart(() => {
                      this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                    })
                    .onActionUpdate((e: GestureEvent) => {
                      this.onCropHandleDrag(5, e);
                    })
                )
              // 下边中点
              Column()
                .width(30).height(3).borderRadius(1.5).backgroundColor(Color.White)
                .position({ x: this.cropX + this.cropW / 2 - 15, y: this.cropY + this.cropH - 2 })
                .responseRegion({ x: -18, y: -14, width: 66, height: 31 })
                .gesture(
                  PanGesture()
                    .onActionStart(() => {
                      this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                    })
                    .onActionUpdate((e: GestureEvent) => {
                      this.onCropHandleDrag(6, e);
                    })
                )
              // 左边中点
              Column()
                .width(3).height(30).borderRadius(1.5).backgroundColor(Color.White)
                .position({ x: this.cropX - 2, y: this.cropY + this.cropH / 2 - 15 })
                .responseRegion({ x: -14, y: -18, width: 31, height: 66 })
                .gesture(
                  PanGesture()
                    .onActionStart(() => {
                      this.handleBase = { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
                    })
                    .onActionUpdate((e: GestureEvent) => {
                      this.onCropHandleDrag(7, e);
                    })
                )

              // 九宫格辅助线（2 横 2 竖，把选区分成 9 等份，辅助构图）
              Column()
                .width(this.cropW)
                .height(0.5)
                .backgroundColor('#80FFFFFF')
                .position({ x: this.cropX, y: this.cropY + this.cropH / 3 })
                .hitTestBehavior(HitTestMode.None)
              Column()
                .width(this.cropW)
                .height(0.5)
                .backgroundColor('#80FFFFFF')
                .position({ x: this.cropX, y: this.cropY + this.cropH * 2 / 3 })
                .hitTestBehavior(HitTestMode.None)
              Column()
                .width(0.5)
                .height(this.cropH)
                .backgroundColor('#80FFFFFF')
                .position({ x: this.cropX + this.cropW / 3, y: this.cropY })
                .hitTestBehavior(HitTestMode.None)
              Column()
                .width(0.5)
                .height(this.cropH)
                .backgroundColor('#80FFFFFF')
                .position({ x: this.cropX + this.cropW * 2 / 3, y: this.cropY })
                .hitTestBehavior(HitTestMode.None)
            }
            if (!(this.tool === 'crop' && this.cropVisible)) {
              // 非裁剪态：图片不可移动
              Image(this.curPixelMap)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
            }

            // 裁剪态下隐藏文字/贴纸：它们不参与裁剪，且会浮在选区上方抢走拖动手势
            if (!(this.tool === 'crop' && this.cropVisible)) {
            // 文字叠加（多行 + 风格）—— 渲染内容已搬到 @Builder textLayer()（阶段 5 第 3a 步）
            ForEach(this.texts, (t: TextItem, idx: number) => {
              this.textLayer(t, idx)
            }, (t: TextItem, idx: number) => idx.toString())

            // ===== 贴纸层（抠图/相册 PNG，可拖拽缩放旋转） =====
            // 贴纸层渲染内容已搬到 @Builder stickerLayer()（阶段 5 第 3b 步）
            ForEach(this.stickers, (s: StickerItem, idx: number) => {
              this.stickerLayer(s, idx)
            }, (s: StickerItem, idx: number) => idx.toString())
            }

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
            this.previewW = newValue.width as number;
            this.previewH = newValue.height as number;
            this.invalidateDisp();
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
                  this.rotateImage(-90);
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
                        .fontColor(this.cropVisible && this.cropRatio === r ? Color.White : '#555555')
                        .backgroundColor(this.cropVisible && this.cropRatio === r ? '#FF6B6B' : Color.White)
                        .border({ width: 1, color: this.cropVisible && this.cropRatio === r ? '#FF6B6B' : '#DDDDDD' })
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
                    this.rotateImage(-90);
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
                      this.cropVisible = false;
                      this.cropRatio = '自由';
                      this.cropOffsetX = 0;
                      this.cropOffsetY = 0;
                      this.cropScale = 1;
                      this.cropAngle = 0;
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
                    .onChange((v: number) => {
                      this.textureStrength = v;
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
                        this.texts = [];
                        this.selectedText = -1;
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
                              if (this.selectedText >= 0 && this.selectedText < this.texts.length) {
                                const t: TextItem = this.texts[this.selectedText];
                                t.color = c;
                                this.refreshTexts();
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
                      this.stickers = [];
                      this.selectedSticker = -1;
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
