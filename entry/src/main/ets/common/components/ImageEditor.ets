﻿﻿﻿﻿﻿﻿import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { taskpool } from '@kit.ArkTS';
import { Wallpaper } from '../../model/Wallpaper';
import { runFilterTask, runTextureTask } from '../editor/FilterTask';
import { runPerspectiveTask } from '../editor/PerspectiveTask';
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
  cropComposeTransform,
  autoCropScale
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
import { ImageCache } from '../net/ImageCache';
import { AuthManager } from '../net/AuthManager';
import { Haptics } from '../utils/Haptics';

/**
 * 线性混合（UI 线程内联版）：out = base + (filt − base)·k
 *
 * 为什么不再走 TaskPool：混合是"每像素一次乘加"的纯线性运算，本身很便宜；
 * 真正贵的是 taskpool 每次往返搬运 ~10MB×2 缓冲（实测每次 3~4s）。
 * 内联后单帧只需一次内存遍历，滑杆拖动才能实时跟手。
 */
function mixLinear(base: ArrayBuffer, filt: ArrayBuffer, k: number): ArrayBuffer {
  const b: Uint8Array = new Uint8Array(base);
  const f: Uint8Array = new Uint8Array(filt);
  const n: number = f.byteLength;
  const out: Uint8Array = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    const v: number = b[i] + (f[i] - b[i]) * k;
    out[i] = v < 0 ? 0 : (v > 255 ? 255 : v) | 0;
  }
  return out.buffer as ArrayBuffer;
}

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
 * 历史快照条目（撤销/重做栈元素）
 *
 * 底图不存 RGBA 原图（8MB×12 ≈ 96MB 太贵），存质量 88 的 JPEG（约 300-600KB），
 * 恢复时重新解码；图层元素全部深拷贝（贴纸 content 只是路径字符串，可直接复制）。
 */
interface HistoryEntry {
  jpeg: ArrayBuffer;
  imageW: number;
  imageH: number;
  filterName: string;
  textureName: string;
  textureStrength: number;
  filterIntensity: number;
  fitMode: string;
  texts: TextItem[];
  stickers: StickerItem[];
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
  /** 滤镜/纹理后台处理中（TaskPool）；同时作为"丢弃中间帧"的并发闸门 */
  @State processing: boolean = false;
  /**
   * 是否显示"处理中"遮罩。只在真正耗时的重算（滤镜/纹理首次满档计算、几何/裁剪）时显示；
   * 拖强度滑杆只跑几十毫秒的 mix，若也遮罩会盖住预览 → 用户看不见实时变化（误以为"没反应"）。
   */
  @State showBusy: boolean = false;

  /** 当前工具页 */
  @State tool: string = 'transform';
  /** 当前滤镜 */
  @State filterName: string = '原图';
  /** 当前滤镜强度（0-100；100=满档；仅在选中滤镜时可调） */
  @State filterIntensity: number = 100;
  /** 当前纹理与强度 */
  @State textureName: string = '';
  @State textureStrength: number = 70;
  @State showTextInput: boolean = false;
  @State textInput: string = '';
  @State textColor: string = '#FFFFFF';
  @State textStyle: number = 0;
  /** 我的抠图贴纸（文件路径） */
  @State userStickers: string[] = [];
  /** 底部工具面板是否收起（收起后预览区最大化，点工具 chip 自动展开） */
  @State panelCollapsed: boolean = false;
  /** 预设文案分段：0=主题文字，1=励志语录 */
  @State phraseTab: number = 0;
  /** 裁剪面板内"微调"区是否展开（拉直/水平/垂直，默认收起：先裁剪再微调） */
  @State cropAdjustExpanded: boolean = false;

  // ===== 撤销/重做（S2）=====
  private undoStack: HistoryEntry[] = [];
  private redoStack: HistoryEntry[] = [];
  /** 栈上限（JPEG 快照，约 0.5MB/步） */
  private readonly HISTORY_MAX: number = 12;
  @State canUndo: boolean = false;
  @State canRedo: boolean = false;
  /**
   * 历史操作串行闸门：「快照捕获 → 动作执行」必须原子，
   * 否则快速连点时快照可能捕获到上一个动作完成后的状态，历史错乱。
   */
  private histGate: Promise<void> = Promise.resolve();
  /** 满档滤镜结果缓存（强度滑杆只跑 mix，不重算滤镜） */
  private filterFullBytes: ArrayBuffer | undefined = undefined;
  private filterFullName: string = '';
  /** 满档纹理结果缓存（强度滑杆只跑 mix，不重算纹理） */
  private textureFullBytes: ArrayBuffer | undefined = undefined;
  private textureFullName: string = '';
  /** 满档纹理对应的"输入阶段"指纹（=baseVersion|滤镜名|滤镜强度），变了就作废 */
  private textureFullKey: string = '';
  /** 底图像素缓存（底图只在几何变换/重载后变化，拖滑杆时无需重复读 8MB） */
  private baseBytesCache: ArrayBuffer | undefined = undefined;
  /** 底图版本号：每次几何烘焙/重载/恢复自增，用于纹理缓存失效判定 */
  private baseVersion: number = 0;
  /** 处理中被丢弃的强度刷新帧，完成后补一次最终值 */
  private intensityPending: boolean = false;

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
      // 底图来源：云端壁纸（即使有随包兜底图）取高清原图；纯本地壁纸读随包资源。
      let data: ArrayBuffer;
      if (this.wallpaper.isCloud) {
        // 走三级缓存：浏览过的图再编辑零流量、断网可编辑（init 幂等防御入口遗漏）
        ImageCache.init(ctx);
        data = await ImageCache.fetchBytes(
          (this.wallpaper.imageUrl.length > 0)
            ? this.wallpaper.imageUrl : this.wallpaper.thumbUrl);
      } else if (this.localImg !== undefined) {
        const content: Uint8Array = await ctx.resourceManager.getMediaContent(this.localImg);
        data = content.buffer as ArrayBuffer;
      } else {
        return;
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
      this.filterIntensity = 100;
      this.textureName = NO_TEXTURE;
      this.invalidateProcessCaches();
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
   * 管线：`stage = 底图经滤镜(强度 kf)`；`画面 = stage 经纹理(强度 kt)`。
   *  - 滤镜/纹理各有"满档(k=1)结果缓存"，拖动强度滑杆只做一次 UI 线程内联线性混合
   *    `mixLinear`（一次内存遍历，毫秒级），不再每次全量重算；
   *  - **满档缓存只读**：TaskPool 任务都改成"只读输入、写独立输出"，
   *    且入参一律传一次性副本（TaskPool 会转移 ArrayBuffer 所有权，直接传缓存会
   *    让缓存失效 → `TypeError: IsDetachedBuffer`），因此缓存永不被写坏或吞掉；
   *  - 纹理缓存的"输入阶段指纹" = baseVersion|滤镜名|滤镜强度：任一项变化即重算。
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
          // ===== 1) 底图 →(滤镜)→ stage =====
          let stage: ArrayBuffer;
          if (this.filterName !== NO_FILTER) {
            const kf: number = this.filterIntensity / 100;
            const needBuild: boolean = this.filterFullBytes === undefined
              || this.filterFullName !== this.filterName;
            if (!needBuild && kf >= 1) {
              // 满档 + 缓存命中：连底图都不用读
              stage = this.filterFullBytes as ArrayBuffer;
            } else {
              const baseBytes: ArrayBuffer = await this.readBaseBytes();
              if (needBuild) {
                this.showBusy = true;
                // TaskPool 默认「转移」ArrayBuffer 所有权：入参在调用后即失效（IsDetachedBuffer）。
                // 因此传入的必须是**一次性副本**，绝不能把还要复用的缓存缓冲交出去。
                const full: object = await taskpool.execute(runFilterTask, baseBytes.slice(0),
                  w, h, this.filterName);
                this.filterFullBytes = full as ArrayBuffer;
                this.filterFullName = this.filterName;
              }
              const filt: ArrayBuffer = this.filterFullBytes as ArrayBuffer;
              if (kf >= 1) {
                stage = filt;
              } else {
                stage = mixLinear(baseBytes, filt, kf);
              }
            }
          } else {
            stage = await this.readBaseBytes();
          }

          // ===== 2) stage →(纹理)→ 画面 =====
          let bytes: ArrayBuffer = stage;
          if (this.textureName !== NO_TEXTURE) {
            const key: string = `${this.baseVersion}|${this.filterName}|${this.filterIntensity}`;
            if (this.textureFullBytes === undefined || this.textureFullName !== this.textureName
              || this.textureFullKey !== key) {
              this.showBusy = true;
              const full: object = await taskpool.execute(runTextureTask, stage.slice(0), w, h,
                this.textureName, 100);
              this.textureFullBytes = full as ArrayBuffer;
              this.textureFullName = this.textureName;
              this.textureFullKey = key;
            }
            const kt: number = this.textureStrength / 100;
            const tex: ArrayBuffer = this.textureFullBytes as ArrayBuffer;
            if (kt >= 1) {
              bytes = tex;
            } else {
              bytes = mixLinear(stage, tex, kt);
            }
          }
          // commitBytes 内部会 setCurrent + 标脏
          await this.commitBytes(bytes);
        } finally {
          this.processing = false;
          this.showBusy = false;
          // 处理期间被丢弃的滑杆帧：补刷一次最终值
          if (this.intensityPending) {
            this.intensityPending = false;
            this.refreshFromBase(markEdit);
          }
        }
      }
      if (markEdit) {
        this.dirty = true;
      }
    } catch (e) {
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

  /**
   * 旋转入口（两处分发）：
   *  - 裁剪态：框不动、图转（iOS 式），只改 cropAngle + 自动放大保证覆盖；
   *  - 非裁剪态：几何烘焙进底图，走历史栈。
   */
  rotateImage(angle: number): void {
    if (this.model.canvas.cropVisible) {
      this.cropRotate(angle);
      return;
    }
    this.withHistory((): Promise<void> => this.doRotateImage(angle));
  }

  /** 非裁剪态：几何烘焙进底图，滤镜/纹理随后从底图重算（不丢滤镜、不叠色） */
  private async doRotateImage(angle: number): Promise<void> {
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    const dispOld: DispRect = this.dispRect();
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    await base.rotate(angle);
    const tmp: number = this.model.canvas.imageW;
    this.model.canvas.imageW = this.model.canvas.imageH;
    this.model.canvas.imageH = tmp;
    this.invalidateProcessCaches();
    // 文字/贴纸锚点随画面旋转（旋转后尺寸互换）
    this.remapOverlays((p: LayerPoint): LayerPoint => mapRotate(p, angle, oldW, oldH),
      dispOld, oldH, oldW);
    await this.refreshFromBase(true);
  }

  /**
   * 裁剪态 90° 旋转：选区框固定，图片绕预览中心旋转。
   * 竖图转 90 后必然露黑 → autoCropScale 计算最小放大系数并取 max（不回缩）。
   */
  private cropRotate(angle: number): void {
    const delta: number = angle === 90 ? 90 : -90;
    this.model.canvas.cropAngle = this.normalizeAngle180(this.model.canvas.cropAngle + delta);
    this.ensureCropCover();
    this.dirty = true;
    Haptics.light();
  }

  /** 角度归一化到 (-180, 180] */
  private normalizeAngle180(a: number): number {
    let n: number = a;
    while (n > 180) {
      n -= 360;
    }
    while (n <= -180) {
      n += 360;
    }
    return n;
  }

  /**
   * 旋转/拉直后保证图片覆盖预览区：
   * 旋转后图片 AABB 可能盖不住，按 autoCropScale 自动放大（与 iOS 照片一致）。
   */
  private ensureCropCover(): void {
    const view: CropView = this.model.canvas.cropView();
    const need: number = autoCropScale(view, this.model.canvas.previewW,
      this.model.canvas.previewH);
    if (need > this.model.canvas.cropScale) {
      this.model.canvas.cropScale = need;
    }
  }

  /** 翻转入口：裁剪态改镜像标志；非裁剪态烘焙底图走历史栈 */
  flip(horizontal: boolean, vertical: boolean): void {
    if (this.model.canvas.cropVisible) {
      if (horizontal) {
        this.model.canvas.cropFlipH = !this.model.canvas.cropFlipH;
      }
      if (vertical) {
        this.model.canvas.cropFlipV = !this.model.canvas.cropFlipV;
      }
      this.dirty = true;
      Haptics.light();
      return;
    }
    this.withHistory((): Promise<void> => this.doFlip(horizontal, vertical));
  }

  private async doFlip(horizontal: boolean, vertical: boolean): Promise<void> {
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    const dispOld: DispRect = this.dispRect();
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    await base.flip(horizontal, vertical);
    this.invalidateProcessCaches();
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

  // ==================== 撤销 / 重做（S2） ====================

  /**
   * 处理缓存整体失效（底图像素/几何烘焙/裁剪/重载/撤销恢复后调用）。
   *  - 滤镜/纹理满档缓存、底图字节缓存都不再对应当前底图；
   *  - 同时自增 baseVersion，使纹理缓存的"输入阶段指纹"失配。
   */
  private invalidateProcessCaches(): void {
    this.filterFullBytes = undefined;
    this.filterFullName = '';
    this.textureFullBytes = undefined;
    this.textureFullName = '';
    this.textureFullKey = '';
    this.baseBytesCache = undefined;
    this.baseVersion++;
  }

  /**
   * 读底图像素到独立缓冲（base 随后被替换/释放也不影响）
   *
   * 结果会缓存（底图只在几何变换后变化）。两类保证：
   *  1. 行跨距对齐：`readPixelsToBuffer` 按 getBytesNumberPerRow 给出每行字节数，
   *     若大于 width*4（解码器为 SIMD 对齐做填充），必须逐行压紧，
   *     否则下游按 (y*w+x)*4 索引会整体错位 → 保存后花屏；
   *  2. 三个 TaskPool 任务都改成只读输入，因此这里可以安全返回同一个缓存缓冲
   *     给滤镜/混合/纹理共享，无需每帧拷贝。
   */
  private async readBaseBytes(): Promise<ArrayBuffer> {
    if (this.baseBytesCache !== undefined) {
      return this.baseBytesCache;
    }
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      throw new Error('base pixelmap missing');
    }
    const info = base.getImageInfoSync();
    const w: number = info.size.width;
    const h: number = info.size.height;
    const tightRow: number = w * 4;
    const rowBytes: number = base.getBytesNumberPerRow();
    const raw: ArrayBuffer = new ArrayBuffer(base.getPixelBytesNumber());
    await base.readPixelsToBuffer(raw);
    let tight: ArrayBuffer;
    if (rowBytes === tightRow) {
      tight = raw.byteLength === tightRow * h ? raw : raw.slice(0, tightRow * h);
    } else {
      const srcBuf: Uint8Array = new Uint8Array(raw);
      const outBuf: Uint8Array = new Uint8Array(tightRow * h);
      for (let y = 0; y < h; y++) {
        outBuf.set(srcBuf.subarray(y * rowBytes, y * rowBytes + tightRow), y * tightRow);
      }
      tight = outBuf.buffer as ArrayBuffer;
    }
    this.baseBytesCache = tight;
    return tight;
  }

  /** RGBA 字节打包成 JPEG（ImageKit 硬编，约 50-100ms） */
  private async packJpeg(bytes: ArrayBuffer, w: number, h: number): Promise<ArrayBuffer> {
    const opts: image.InitializationOptions = {
      size: { width: w, height: h },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888
    };
    const pm: image.PixelMap = await image.createPixelMap(bytes, opts);
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      return await packer.packing(pm, { format: 'image/jpeg', quality: 88 });
    } finally {
      try {
        packer.release();
      } catch (e) {
        // 忽略
      }
      PixelScope.safeRelease(pm);
    }
  }

  /** 文字图层深拷贝 */
  private copyTexts(src: TextItem[]): TextItem[] {
    const out: TextItem[] = [];
    for (let i = 0; i < src.length; i++) {
      const t: TextItem = src[i];
      out.push({ content: t.content, color: t.color, x: t.x, y: t.y, scale: t.scale, style: t.style });
    }
    return out;
  }

  /** 贴纸图层深拷贝（content 是路径字符串） */
  private copyStickers(src: StickerItem[]): StickerItem[] {
    const out: StickerItem[] = [];
    for (let i = 0; i < src.length; i++) {
      const s: StickerItem = src[i];
      out.push({ content: s.content, x: s.x, y: s.y, scale: s.scale, angle: s.angle });
    }
    return out;
  }

  /** 捕获当前状态（只捕获、不入栈） */
  private async captureEntry(): Promise<HistoryEntry> {
    const w: number = this.model.canvas.imageW;
    const h: number = this.model.canvas.imageH;
    const rgba: ArrayBuffer = await this.readBaseBytes();
    const jpeg: ArrayBuffer = await this.packJpeg(rgba, w, h);
    return {
      jpeg: jpeg,
      imageW: w,
      imageH: h,
      filterName: this.filterName,
      textureName: this.textureName,
      textureStrength: this.textureStrength,
      filterIntensity: this.filterIntensity,
      fitMode: this.model.canvas.fitMode,
      texts: this.copyTexts(this.model.layers.texts()),
      stickers: this.copyStickers(this.model.layers.stickers())
    };
  }

  /**
   * 执行一个可撤销操作：串行闸门内「先快照 → 再动作」。
   * 所有破坏性操作（旋转/翻转/裁剪/滤镜/纹理/图层增删）的唯一入口。
   */
  private withHistory(action: () => Promise<void>): void {
    this.histGate = this.histGate.then(async (): Promise<void> => {
      try {
        const entry: HistoryEntry = await this.captureEntry();
        this.undoStack.push(entry);
        while (this.undoStack.length > this.HISTORY_MAX) {
          this.undoStack.shift();
        }
        this.redoStack = [];
        this.updateHistoryButtons();
        await action();
      } catch (e) {
        console.error(`history action failed: ${JSON.stringify(e)}`);
        promptAction.showToast({ message: '操作失败，请重试' });
      }
    });
  }

  /**
   * 滑杆开始调节时入一次历史（一次拖动手势 = 一个撤销步）。
   * 只挂「快照入栈」，动作（实时刷新）不经过闸门。
   */
  private beginSliderHistory(): void {
    this.histGate = this.histGate.then(async (): Promise<void> => {
      try {
        const entry: HistoryEntry = await this.captureEntry();
        this.undoStack.push(entry);
        while (this.undoStack.length > this.HISTORY_MAX) {
          this.undoStack.shift();
        }
        this.redoStack = [];
        this.updateHistoryButtons();
      } catch (e) {
        console.error(`slider history failed: ${JSON.stringify(e)}`);
      }
    });
  }

  /** 恢复一个历史条目（jpeg 解码为底图 → 图层 → 滤镜状态 → 重算画面） */
  private async restoreEntry(entry: HistoryEntry): Promise<void> {
    // 1. JPEG → 可编辑 RGBA 底图
    const src: image.ImageSource = image.createImageSource(entry.jpeg);
    const pm: image.PixelMap = await src.createPixelMap({ editable: true });
    try {
      src.release();
    } catch (e) {
      // 忽略
    }
    this.basePixelMap = this.baseScope.setCurrent(await this.toEditableRgba(pm));
    this.model.canvas.imageW = entry.imageW;
    this.model.canvas.imageH = entry.imageH;
    this.model.canvas.fitMode = entry.fitMode;
    // 2. 图层整体恢复（元素由快照深拷贝，store 直接接管）
    this.model.layers.restoreSnapshot(entry.texts, entry.stickers);
    // 3. 滤镜链状态
    this.filterName = entry.filterName;
    this.filterIntensity = entry.filterIntensity;
    this.textureName = entry.textureName;
    this.textureStrength = entry.textureStrength;
    this.invalidateProcessCaches();
    // 4. 重算画面（非用户动作，不重复标脏）
    await this.refreshFromBase(false);
  }

  /** 撤销 */
  undo(): void {
    if (!this.canUndo) {
      return;
    }
    Haptics.light();
    this.histGate = this.histGate.then(async (): Promise<void> => {
      const entry: HistoryEntry | undefined = this.undoStack.pop();
      if (entry === undefined) {
        return;
      }
      const current: HistoryEntry = await this.captureEntry();
      this.redoStack.push(current);
      await this.restoreEntry(entry);
      // 撤销栈空 = 回到本次编辑的初始态：关闭不再确认
      if (this.undoStack.length === 0) {
        this.dirty = false;
        this.model.layers.markClean();
      } else {
        this.dirty = true;
      }
      this.updateHistoryButtons();
    });
  }

  /** 重做 */
  redo(): void {
    if (!this.canRedo) {
      return;
    }
    Haptics.light();
    this.histGate = this.histGate.then(async (): Promise<void> => {
      const entry: HistoryEntry | undefined = this.redoStack.pop();
      if (entry === undefined) {
        return;
      }
      const current: HistoryEntry = await this.captureEntry();
      this.undoStack.push(current);
      await this.restoreEntry(entry);
      this.dirty = true;
      this.updateHistoryButtons();
    });
  }

  private updateHistoryButtons(): void {
    this.canUndo = this.undoStack.length > 0;
    this.canRedo = this.redoStack.length > 0;
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

  /**
   * 拉直 / 水平 / 垂直校正滑杆（CanvasView 回报）
   *  - straighten：直接驱动 cropAngle（与 90 按钮共用角度；动滑杆即放弃整圈部分），
   *    并自动放大保证旋转后覆盖；
   *  - perspectiveH/V：只改状态，applyCrop 确认时 PerspectiveTask 烘焙。
   */
  private onCropAdjust(kind: string, value: number, mode: SliderChangeMode): void {
    if (kind === 'straighten') {
      this.model.canvas.cropAngle = value;
      this.ensureCropCover();
    } else if (kind === 'perspectiveH') {
      this.model.canvas.perspectiveH = value;
    } else if (kind === 'perspectiveV') {
      this.model.canvas.perspectiveV = value;
    }
    this.dirty = true;
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

  applyCrop(): void {
    // 裁的是**底图**（几何）：滤镜/纹理随后从新底图重算，效果不会丢
    if (this.basePixelMap === undefined || !this.model.canvas.cropVisible) {
      return;
    }
    this.withHistory((): Promise<void> => this.doApplyCrop());
  }

  private async doApplyCrop(): Promise<void> {
    const base: image.PixelMap | undefined = this.basePixelMap;
    if (base === undefined) {
      return;
    }
    const dispOld: DispRect = this.dispRect();
    const oldW: number = this.model.canvas.imageW;
    const oldH: number = this.model.canvas.imageH;
    // 选区与图片变换都取自 CanvasState（与 UI 使用的是同一份数据）
    const rect: CropRect = this.model.canvas.cropRect();
    const view: CropView = this.model.canvas.cropView();
    const pH: number = this.model.canvas.perspectiveH;
    const pV: number = this.model.canvas.perspectiveV;
    this.processing = true;
    this.showBusy = true;
    try {
      // 与 UI 同一套变换在离屏画布上重绘 → 缩放/平移/旋转/镜像都被正确带进结果
      const res: CropComposeResult = await composeCropToPixelMap(base, oldW, oldH, rect, view,
        CanvasSpec.MAX_LONG_EDGE);
      let cropPm: image.PixelMap = res.pixelMap;
      // 水平/垂直透视校正：几何烘焙后逐像素重映射（与预览矩阵同一套数学）
      if (Math.abs(pH) > 0 || Math.abs(pV) > 0) {
        const pbytes: ArrayBuffer = new ArrayBuffer(cropPm.getPixelBytesNumber());
        await cropPm.readPixelsToBuffer(pbytes);
        const fixed: object = await taskpool.execute(runPerspectiveTask, pbytes,
          res.width, res.height, pH, pV);
        cropPm = await image.createPixelMap(fixed as ArrayBuffer, {
          size: { width: res.width, height: res.height },
          pixelFormat: image.PixelMapFormat.RGBA_8888,
          editable: true
        });
        // 旧的离屏产物释放（baseScope.setCurrent 只接管 cropPm）
        PixelScope.safeRelease(res.pixelMap);
      }
      this.model.canvas.imageW = res.width;
      this.model.canvas.imageH = res.height;
      // 裁剪产物归一化成可编辑的 RGBA 底图，后续旋转/翻转才能原地改
      this.basePixelMap = this.baseScope.setCurrent(await this.toEditableRgba(cropPm));
      this.invalidateProcessCaches();
      // 图层锚点重映射（正向投影，与 composeCropToPixelMap 同一套变换）：
      //   旧源像素 p → 镜像 → 旋转/缩放/平移 → 输出画布像素 = 新图像素
      // 之前用 unprojectCrop（逆变换）且输入未考虑裁剪态变换，导致文字/贴纸裁剪后错位。
      const tCompose: CropDrawTransform = cropComposeTransform(rect, view, res.canvasScale);
      const cosA: number = Math.cos(tCompose.radians);
      const sinA: number = Math.sin(tCompose.radians);
      const sx: number = view.flipH ? -1 : 1;
      const sy: number = view.flipV ? -1 : 1;
      this.remapOverlays((p: LayerPoint): LayerPoint => {
        // 先逆镜像（与 composeCropToPixelMap 中 drawImage 偏移方向一致）
        const ox: number = sx < 0 ? oldW - 1 - p.x : p.x;
        const oy: number = sy < 0 ? oldH - 1 - p.y : p.y;
        // 正向变换到输出画布像素（= 新图像素，画布与新图 1:1）
        const nx: number = tCompose.tx + tCompose.scale * (ox * cosA - oy * sinA);
        const ny: number = tCompose.ty + tCompose.scale * (ox * sinA + oy * cosA);
        return { x: nx, y: ny };
      }, dispOld, this.model.canvas.imageW, this.model.canvas.imageH);
      // 提交后退出裁剪态并复位（选区、比例、图片变换、透视量）
      this.model.canvas.clearCrop();
      await this.refreshFromBase(true);
      promptAction.showToast({ message: '已裁剪 ✅' });
    } catch (e) {
      console.error(`applyCrop failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '裁剪失败，请重试' });
      this.model.canvas.cropVisible = false;
    } finally {
      this.processing = false;
      this.showBusy = false;
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
   * 应用滤镜：从**底图**重算，逐像素计算在 TaskPool 工作线程，
   * 只跨线程传 ArrayBuffer，不传 PixelMap；重复点击由历史闸门串行化。
   *
   * 再点一次当前滤镜 = 取消（回到原图色）；换一个滤镜 = 换掉，不叠色。
   */
  applyFilter(name: string): void {
    if (this.basePixelMap === undefined) {
      return;
    }
    if (name === NO_FILTER) {
      // 点「原图」= 清滤镜链（也可撤销：恢复滤镜状态）
      this.withHistory((): Promise<void> => this.clearFilterChain());
      return;
    }
    this.withHistory((): Promise<void> => this.doApplyFilter(name));
  }

  /** 清掉滤镜链并复位强度（action 体） */
  private async clearFilterChain(): Promise<void> {
    this.filterName = NO_FILTER;
    this.filterIntensity = 100;
    this.textureName = NO_TEXTURE;
    this.invalidateProcessCaches();
    await this.refreshFromBase(true);
  }

  private async doApplyFilter(name: string): Promise<void> {
    // 再点一次当前滤镜 = 取消（回原图色），换一个 = 换掉，不叠色
    const toggled: string = toggleFilter(this.filterName, name);
    if (toggled === NO_FILTER) {
      this.filterName = NO_FILTER;
      this.filterIntensity = 100;
      this.invalidateProcessCaches();
    } else {
      this.filterName = toggled;
      this.filterIntensity = 100;
      this.invalidateProcessCaches();
    }
    await this.refreshFromBase(true);
  }

  // ==================== 纹理叠加 ====================

  /**
   * 应用纹理：同样从底图重算 —— 管线是"底图 → 滤镜 → 纹理"，强度取 textureStrength。
   * 再点一次当前纹理 = 取消。
   */
  applyTexture(name: string): void {
    if (name === '' || this.basePixelMap === undefined) {
      return;
    }
    this.withHistory((): Promise<void> => this.doApplyTexture(name));
  }

  private async doApplyTexture(name: string): Promise<void> {
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
    this.withHistory((): Promise<void> => this.doAddText(text));
  }

  /** action 体：级联偏移避免新文字全叠在画面中心 */
  private async doAddText(text: string): Promise<void> {
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
    this.withHistory((): Promise<void> => this.doRemoveText(idx));
  }

  private async doRemoveText(idx: number): Promise<void> {
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
    this.withHistory((): Promise<void> => this.doPushSticker(content));
  }

  private async doPushSticker(content: string): Promise<void> {
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
    this.withHistory((): Promise<void> => this.doRemoveSticker(idx));
  }

  private async doRemoveSticker(idx: number): Promise<void> {
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
    // 产品规则：导出到相册必须登录（浏览与编辑本身不要求登录）
    if (!AuthManager.getInstance().isLoggedIn()) {
      AuthManager.getInstance().showAuthOverlay();
      promptAction.showToast({ message: '请先登录后再保存图片' });
      return;
    }
    const pm0: image.PixelMap | undefined = this.curPixelMap;
    if (pm0 === undefined) {
      return;
    }
    this.saving = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let dest: string = '';
    try {
      // 裁剪态直接点保存：先应用裁剪再导出。
      // 此前只是 cropVisible=false 把框藏起来，裁剪被静默丢弃 —— 用户框选的内容没进成品。
      if (this.model.canvas.isCropping()) {
        await this.doApplyCrop();
      }
      this.model.canvas.cropVisible = false;
      const pm: image.PixelMap | undefined = this.curPixelMap;
      if (pm === undefined) {
        return;
      }
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
      .fontColor(this.tool === key ? Color.White : '#1F1F1F')
      .backgroundColor(this.tool === key ? '#C22F38' : '#F0F0F0')
      // 收窄左右内边距，让 6 个工具 chip 在常见机型上一屏放得下
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => {
        this.tool = key;
        this.panelCollapsed = false;
        if (key === 'crop' && !this.model.canvas.cropVisible) {
          this.selectCropRatio('自由');
        }
      })
  }

  @Builder
  phraseChip(p: string, color: string, bg: string) {
    Text(p)
      .fontSize(12)
      .fontColor(color)
      .backgroundColor(bg)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(10)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.addPhrase(p);
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
          .color('#C22F38')
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
            // 撤销 / 重做（禁用态变浅：点击无响应）
            Text('↶')
              .fontSize(22)
              .fontColor(this.canUndo ? '#333333' : '#CCCCCC')
              .width(44)
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.undo();
              })
            Text('↷')
              .fontSize(22)
              .fontColor(this.canRedo ? '#333333' : '#CCCCCC')
              .width(44)
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.redo();
              })
            // 保存中：在标题位显示进度，让用户知道在等什么（此前点了无任何反馈）
            if (this.saving) {
              Row({ space: 6 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color('#C22F38')
                Text('正在保存…')
                  .fontSize(13)
                  .fontColor('#66666F')
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
                  if (!AuthManager.getInstance().isLoggedIn()) {
                    AuthManager.getInstance().showAuthOverlay();
                    promptAction.showToast({ message: '请先登录后再保存图片' });
                    return;
                  }
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
              },
              onCropAdjust: (kind: string, value: number, mode: SliderChangeMode): void => {
                this.onCropAdjust(kind, value, mode);
              }
            })

            // ===== 后台处理遮罩（滤镜/纹理重算期间盖在预览最上层；滑杆 mix 不遮） =====
            if (this.showBusy) {
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

          // ===== 工具 tab + 收起开关 =====
          Row({ space: 8 }) {
            Scroll() {
              Row({ space: 8 }) {
                this.toolChip('旋转/翻转', 'transform')
                this.toolChip('裁剪', 'crop')
                this.toolChip('滤镜', 'filter')
                this.toolChip('纹理', 'texture')
                this.toolChip('文字', 'text')
                this.toolChip('贴纸', 'sticker')
              }
              // 右侧留出滚动余量，滚到末尾时最后一个 chip 不会被收起按钮截断
              .padding({ left: 2, right: 12, top: 8, bottom: 6 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)
            .edgeEffect(EdgeEffect.Spring)

            Text(this.panelCollapsed ? '🔼' : '🔽')
              .fontSize(13)
              .fontColor('#66666F')
              .backgroundColor('#F0F0F0')
              .width(34)
              .height(30)
              .textAlign(TextAlign.Center)
              .borderRadius(14)
              .onClick(() => {
                this.panelCollapsed = !this.panelCollapsed;
              })
          }
          .width('100%')
          .padding({ left: 10, right: 10 })

          // ===== 工具面板（收起时整块隐藏，预览区最大化） =====
          if (!this.panelCollapsed) {
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
                          ? '#C22F38' : Color.White)
                        .border({
                          width: 1,
                          color: this.canvas.cropVisible && this.canvas.cropRatio === r
                            ? '#C22F38' : '#DDDDDD'
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
                .edgeEffect(EdgeEffect.Spring)

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

                // ===== 微调折叠区：拉直/水平/垂直（默认收起，先裁剪再微调） =====
                Row({ space: 6 }) {
                  Text('微调')
                    .fontSize(12)
                    .fontColor('#66666F')
                  Text(this.cropAdjustExpanded ? '▾' : '▸')
                    .fontSize(10)
                    .fontColor('#66666F')
                  Blank()
                  if (this.cropAdjustExpanded) {
                    Text('↺ 复位')
                      .fontSize(11)
                      .fontColor('#C22F38')
                      .backgroundColor('#FFF0F1')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .borderRadius(10)
                      .onClick(() => {
                        this.onCropAdjust('straighten', 0, SliderChangeMode.Click);
                        this.onCropAdjust('perspectiveH', 0, SliderChangeMode.Click);
                        this.onCropAdjust('perspectiveV', 0, SliderChangeMode.Click);
                      })
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14 })
                .onClick(() => {
                  this.cropAdjustExpanded = !this.cropAdjustExpanded;
                })

                if (this.cropAdjustExpanded) {
                  // 拉直
                  Row({ space: 8 }) {
                    Text('拉直')
                      .fontSize(11).fontColor('#66666F').width(36)
                    Slider({
                      value: this.canvas.cropAngle,
                      min: -45, max: 45, step: 1
                    })
                      .layoutWeight(1)
                      .selectedColor('#C22F38')
                      .onChange((v: number, mode: SliderChangeMode) => {
                        this.onCropAdjust('straighten', v, mode);
                      })
                    Text(`${Math.round(this.canvas.cropAngle)}°`)
                      .fontSize(10).fontColor('#66666F').width(34)
                  }
                  .width('100%')
                  .padding({ left: 14, right: 8 })

                  // 水平透视
                  Row({ space: 8 }) {
                    Text('水平')
                      .fontSize(11).fontColor('#66666F').width(36)
                    Slider({
                      value: this.canvas.perspectiveH,
                      min: -100, max: 100, step: 1
                    })
                      .layoutWeight(1)
                      .selectedColor('#C22F38')
                      .onChange((v: number, mode: SliderChangeMode) => {
                        this.onCropAdjust('perspectiveH', v, mode);
                      })
                    Text(`${Math.round(this.canvas.perspectiveH)}`)
                      .fontSize(10).fontColor('#66666F').width(34)
                  }
                  .width('100%')
                  .padding({ left: 14, right: 8 })

                  // 垂直透视
                  Row({ space: 8 }) {
                    Text('垂直')
                      .fontSize(11).fontColor('#66666F').width(36)
                    Slider({
                      value: this.canvas.perspectiveV,
                      min: -100, max: 100, step: 1
                    })
                      .layoutWeight(1)
                      .selectedColor('#C22F38')
                      .onChange((v: number, mode: SliderChangeMode) => {
                        this.onCropAdjust('perspectiveV', v, mode);
                      })
                    Text(`${Math.round(this.canvas.perspectiveV)}`)
                      .fontSize(10).fontColor('#66666F').width(34)
                  }
                  .width('100%')
                  .padding({ left: 14, right: 8 })
                }

                // 操作按钮：重置 | 取消 | 应用（合并一行，主要按钮稍宽引导点击）
                Row({ space: 8 }) {
                  Text('重置')
                    .fontSize(13)
                    .fontColor('#1F1F1F')
                    .backgroundColor('#F2F2F2')
                    .layoutWeight(1)
                    .height(34)
                    .textAlign(TextAlign.Center)
                    .borderRadius(17)
                    .onClick(() => {
                      this.resetCrop();
                    })
                  Text('取消')
                    .fontSize(13)
                    .fontColor('#1F1F1F')
                    .backgroundColor('#F2F2F2')
                    .layoutWeight(1)
                    .height(34)
                    .textAlign(TextAlign.Center)
                    .borderRadius(17)
                    .onClick(() => {
                      this.model.canvas.clearCrop();
                    })
                  Text('✓ 应用')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .backgroundColor('#C22F38')
                    .layoutWeight(1.2)
                    .height(34)
                    .textAlign(TextAlign.Center)
                    .borderRadius(17)
                    .shadow({ radius: 4, color: '#33C9333D', offsetY: 1 })
                    .onClick(() => {
                      this.applyCrop();
                    })
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
                .justifyContent(FlexAlign.Center)
              }
              .width('100%')
              .padding({ top: 2, bottom: 2 })
            } else if (this.tool === 'filter') {
              Column({ space: 4 }) {
                Scroll() {
                  Column({ space: 8 }) {
                    Row({ space: 8 }) {
                      ForEach(BASE_FILTERS, (f: string) => {
                        Text(f)
                          .fontSize(13)
                          .fontColor(this.filterName === f ? Color.White : '#1F1F1F')
                          .backgroundColor(this.filterName === f ? '#C22F38' : '#F0F0F0')
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
                .height(78)
                .edgeEffect(EdgeEffect.Spring)

                // 滤镜强度（仅选中滤镜时显示；一次调节 = 一个撤销步）
                if (this.filterName !== NO_FILTER) {
                  Row({ space: 10 }) {
                    Text('强度')
                      .fontSize(12)
                      .fontColor('#66666F')
                    Slider({ value: this.filterIntensity, min: 0, max: 100, step: 1 })
                      .layoutWeight(1)
                      .selectedColor('#C22F38')
                      .onChange((v: number, mode: SliderChangeMode) => {
                        if (mode === SliderChangeMode.Begin) {
                          this.beginSliderHistory();
                        } else if (mode === SliderChangeMode.Click) {
                          this.beginSliderHistory();
                        }
                        this.filterIntensity = v;
                        if (!this.processing) {
                          this.refreshFromBase(true);
                        } else {
                          this.intensityPending = true;
                        }
                      })
                    Text(`${this.filterIntensity}%`)
                      .fontSize(12)
                      .fontColor('#61616A')
                      .width(38)
                  }
                  .width('100%')
                  .padding({ left: 12, right: 8 })
                }
              }
              .width('100%')
            } else if (this.tool === 'texture') {
              Column({ space: 8 }) {
                Scroll() {
                  Row({ space: 8 }) {
                    ForEach(TEXTURES, (t: string) => {
                      Text(t)
                        .fontSize(13)
                        .fontColor(this.textureName === t ? Color.White : '#666666')
                        .backgroundColor(this.textureName === t ? '#C22F38' : '#F0F0F0')
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
                .edgeEffect(EdgeEffect.Spring)

                Row({ space: 10 }) {
                  Text('强度')
                    .fontSize(12)
                    .fontColor('#66666F')
                  Slider({ value: this.textureStrength, min: 0, max: 100, step: 1 })
                    .layoutWeight(1)
                    .selectedColor('#C22F38')
                    .onChange((v: number, mode: SliderChangeMode) => {
                      // BUG2：此前只有 End 重绘，点轨道（Click）画面不动
                      if (mode === SliderChangeMode.Begin
                        || mode === SliderChangeMode.Click) {
                        this.beginSliderHistory();
                      }
                      this.textureStrength = v;
                      if (this.textureName !== '') {
                        // 处理中自动丢弃中间帧，结束后补最终值（intensityPending）
                        if (!this.processing) {
                          this.refreshFromBase(true);
                        } else {
                          this.intensityPending = true;
                        }
                      }
                    })
                  Text(`${this.textureStrength}%`)
                    .fontSize(12)
                    .fontColor('#61616A')
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
              }
            } else if (this.tool === 'text') {
              Scroll() {
                Column({ space: 8 }) {

                  // ===== 区 1：颜色行 + ✍ 自定义入口 =====
                  Row({ space: 8 }) {
                    ForEach(TEXT_COLORS, (c: string) => {
                      Circle({ width: 22, height: 22 })
                        .fill(c)
                        .border({ width: this.textColor === c ? 2 : 0, color: '#C22F38' })
                        .onClick(() => {
                          this.textColor = c;
                          const idx: number = this.model.layers.selectedText();
                          if (idx >= 0) {
                            this.model.layers.setTextColor(idx, c);
                            this.dirty = true;
                          }
                        })
                    })
                    Blank()
                    Text('✍')
                      .fontSize(16)
                      .fontColor(this.showTextInput ? '#C22F38' : '#666666')
                      .backgroundColor(this.showTextInput ? '#FFF0F1' : '#F0F0F0')
                      .width(32).height(28)
                      .borderRadius(14)
                      .textAlign(TextAlign.Center)
                      .onClick(() => {
                        this.showTextInput = !this.showTextInput;
                      })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12 })

                  // 自定义输入框（点 ✍ 后展开）
                  if (this.showTextInput) {
                    Column({ space: 6 }) {
                      TextArea({ placeholder: '输入文字（可换行）', text: this.textInput })
                        .fontSize(14)
                        .height(60)
                        .onChange((v: string) => {
                          this.textInput = v;
                        })
                      Row({ space: 10 }) {
                        this.opButton('确定', () => {
                          this.addText();
                        })
                        this.opButton('清除全部', () => {
                          this.model.layers.clearTexts();
                          this.dirty = true;
                        })
                        Blank()
                        this.opButton('收起', () => {
                          this.showTextInput = false;
                        })
                      }
                      .width('100%')
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                  }

                  // ===== 区 2：文字风格 =====
                  Row({ space: 8 }) {
                    ForEach(TEXT_STYLES, (s: string, idx: number) => {
                      Text(s)
                        .fontSize(12)
                        .fontColor(this.textStyle === idx ? Color.White : '#1F1F1F')
                        .backgroundColor(this.textStyle === idx ? '#C22F38' : '#F0F0F0')
                        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                        .borderRadius(10)
                        .onClick(() => {
                          this.setTextStyle(idx);
                        })
                    })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)

                  // ===== 区 3：预设文案（分段切换） =====
                  Row({ space: 6 }) {
                    Text('主题文字')
                      .fontSize(11)
                      .fontColor(this.phraseTab === 0 ? Color.White : '#66666F')
                      .backgroundColor(this.phraseTab === 0 ? '#C22F38' : '#F5F5F5')
                      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                      .borderRadius(10)
                      .onClick(() => {
                        this.phraseTab = 0;
                      })
                    Text('励志语录')
                      .fontSize(11)
                      .fontColor(this.phraseTab === 1 ? Color.White : '#66666F')
                      .backgroundColor(this.phraseTab === 1 ? '#C22F38' : '#F5F5F5')
                      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                      .borderRadius(10)
                      .onClick(() => {
                        this.phraseTab = 1;
                      })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)

                  Flex({ wrap: FlexWrap.Wrap }) {
                    if (this.phraseTab === 0) {
                      ForEach(THEME_PHRASES, (p: string) => {
                        this.phraseChip(p, '#C22F38', '#FFF0F1')
                      })
                    } else {
                      ForEach(QUOTE_PHRASES, (p: string) => {
                        this.phraseChip(p, '#666666', '#F5F5F5')
                      })
                    }
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, bottom: 6 })
                }
                .width('100%')
              }
              .scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .constraintSize({ maxHeight: 220 })
              .edgeEffect(EdgeEffect.Spring)
            } else if (this.tool === 'sticker') {
              Scroll() {
                Column({ space: 12 }) {
                  // 我的贴纸（用户从相册导入的透明 PNG；本应用不做自动抠图）
                  Text('我的贴纸（从相册导入，点击添加到画面）')
                    .fontSize(12)
                    .fontColor('#66666F')
                    .width('100%')
                    .padding({ left: 12, top: 4 })
                  if (this.userStickers.length === 0) {
                    Text('还没有贴纸，点下方「相册选贴纸」添加一张吧')
                      .fontSize(12)
                      .fontColor('#66666F')
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
                    .fontColor('#66666F')
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                }
                .width('100%')
              }
              .scrollable(ScrollDirection.Vertical)
              .scrollBar(BarState.Off)
              .width('100%')
              .constraintSize({ maxHeight: 220 })
              .edgeEffect(EdgeEffect.Spring)
            }
          }
          .width('100%')
          .padding({ bottom: 10 })
          }
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
