import { image } from '@kit.ImageKit';
import { componentSnapshot, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { Wallpaper } from '../model/Wallpaper';
import { DefaultWallpapers } from '../common/constants/DefaultWallpapers';
import { CloudDBUtil } from '../common/utils/CloudDBUtil';
import { showSetWallpaperDialog, WallpaperKind } from '../common/components/SetWallpaperGuide';
import { PixelScope } from '../common/utils/PixelScope';
import { EditGuard } from '../common/utils/EditGuard';
import matrix4 from '@ohos.matrix4';

/**
 * 内置宠物插图素材库（PNG 透明插图，文件名去扩展名）
 * 51 张：ot035 系列 5 张 + ot093/ot124 系列各 5 张 + 其余 9 个系列各 4 张
 */
const PET_STICKERS: string[] = [
  'ot035_1', 'ot035_2', 'ot035_3', 'ot035_4', 'ot035_5',
  'ot093', 'ot093_1', 'ot093_2', 'ot093_3', 'ot093_4',
  'ot124', 'ot124_1', 'ot124_2', 'ot124_3', 'ot124_4',
  'ot288', 'ot288_1', 'ot288_2', 'ot288_3',
  'ot304', 'ot304_1', 'ot304_2', 'ot304_3',
  'ot305', 'ot305_1', 'ot305_2', 'ot305_3',
  'ot355', 'ot355_1', 'ot355_2', 'ot355_3',
  'ot372', 'ot372_1', 'ot372_2', 'ot372_3',
  'ot374', 'ot374_1', 'ot374_2', 'ot374_3',
  'ot375', 'ot375_1', 'ot375_2', 'ot375_3',
  'ot396', 'ot396_1', 'ot396_2', 'ot396_3',
  'ot419', 'ot419_1', 'ot419_2', 'ot419_3'
];

/** 贴纸在画布上的基准边长（vp），UI 显示与导出绘制共用此值，保证所见即所得 */
const BASE_STICKER_SIZE: number = 140;

/** 阶段：选背景 → 合成 */
enum Stage {
  PickBg = 0,
  Compose = 1
}

/** 导出目标 */
enum SaveTarget {
  ALBUM_JPG = 0,    // 保存JPG到相册
  ALBUM_PNG = 1,    // 保存透明PNG到相册
  SET_LOCK = 2,     // 存为锁屏壁纸用图（保存后引导用户去图库设置）
  SET_HOME = 3      // 存为桌面壁纸用图（保存后引导用户去图库设置）
}

/**
 * 多贴纸数据项：@Observed 使字段修改能被 @ObjectLink 子组件感知
 *  - x, y：贴纸中心相对预览区中心的偏移（vp）
 *  - scale：缩放（建议 0.3 ~ 4.0）
 *  - angleDeg：旋转角度（度，绕贴纸中心）
 *  - selected：是否选中（驱动虚线高亮框）
 */
@Observed
class StudioSticker {
  id: number = 0;
  resName: string = '';
  x: number = 0;
  y: number = 0;
  scale: number = 1;
  angleDeg: number = 0;
  selected: boolean = false;

  constructor(id: number, resName: string) {
    this.id = id;
    this.resName = resName;
  }
}

/**
 * 单张贴纸节点：@ObjectLink 观察 + Pan/Pinch/Rotation 手势 + 虚线选中框
 *  - 手势直接修改 item 字段（x/y/scale/angleDeg），由 @Observed 推送 UI 刷新
 *  - matrix4 中心变换：平移(预览中心+偏移) × 旋转 × 缩放 × 平移(-w/2,-h/2)
 *    等价于先以贴纸中心为原点做旋转/缩放，再平移到目标位置
 */
@Component
struct StickerNode {
  @ObjectLink item: StudioSticker;
  @Prop canvasW: number = 360;
  @Prop canvasH: number = 640;
  // 阴影实时预览
  @Prop shadowEnabled: boolean = true;
  @Prop shadowOpacity: number = 0.3;
  @Prop shadowBlur: number = 8;
  @Prop shadowOffsetX: number = 0;
  @Prop shadowOffsetY: number = 4;
  // 调色实时预览
  @Prop imgBrightness: number = 0;
  @Prop imgContrast: number = 0;
  onSelect: () => void = () => {};
  onDirty: () => void = () => {};

  private readonly baseSize: number = BASE_STICKER_SIZE;
  private baseX: number = 0;
  private baseY: number = 0;
  private baseScale: number = 1;
  private baseAngle: number = 0;

  /**
   * 中心变换矩阵：平移(偏移 + h) × 旋转 × 缩放 × 平移(-h,-h)
   * 组件在父 Stack 中居中布局（布局原点 = ((W-base)/2, (H-base)/2)），
   * 故此处只需平移「相对中心的偏移 + h」，最终视觉中心 = (W/2 + x, H/2 + y)，
   * 与导出 Canvas 的 translate(compW/2 + x, compH/2 + y) 完全一致。
   */
  private m(): matrix4.Matrix4Transit {
    const h: number = this.baseSize / 2;
    return matrix4.identity()
      .translate({ x: this.item.x + h, y: this.item.y + h, z: 0 })
      .rotate({ x: 0, y: 0, z: 1, angle: this.item.angleDeg })
      .scale({ x: this.item.scale, y: this.item.scale, z: 1 })
      .translate({ x: -h, y: -h, z: 0 });
  }

  build() {
    Stack() {
      // 投影层：同一张图染黑（colorFilter 矩阵 RGB 全输出 0、保留 alpha）+ 高斯模糊 + 透明度 + 偏移
      if (this.shadowEnabled) {
        Image($r(`app.media.${this.item.resName}`))
          .width(this.baseSize)
          .height(this.baseSize)
          .objectFit(ImageFit.Contain)
          .colorFilter([0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0,
                        0, 0, 0, 1, 0])
          .blur(Math.max(0.5, this.shadowBlur * 0.6))
          .opacity(this.shadowOpacity)
          .translate({ x: this.shadowOffsetX, y: this.shadowOffsetY })
          .hitTestBehavior(HitTestMode.None)
      }
      // 贴纸图（资源名 → $r 运行时解析），调色实时生效
      Image($r(`app.media.${this.item.resName}`))
        .width(this.baseSize)
        .height(this.baseSize)
        .objectFit(ImageFit.Contain)
        .brightness(1 + this.imgBrightness)
        .contrast(1 + this.imgContrast)
      // 选中虚线高亮框
      if (this.item.selected) {
        Column()
          .width(this.baseSize)
          .height(this.baseSize)
          .border({ width: 1.5, color: '#FF6B6B', style: BorderStyle.Dashed })
          .borderRadius(6)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.baseSize)
    .height(this.baseSize)
    .transform(this.m())
    .onClick(() => {
      this.onSelect();
    })
    // 拖动走默认手势；缩放/旋转走 parallelGesture（并行手势），
    // 保证双指捏合与旋转都能稳定触发，不被默认手势竞争吞掉
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.onSelect();
          this.baseX = this.item.x;
          this.baseY = this.item.y;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.x = this.baseX + e.offsetX;
          this.item.y = this.baseY + e.offsetY;
          this.onDirty();
        })
    )
    .parallelGesture(
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          this.onSelect();
          this.baseScale = this.item.scale;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.scale = Math.min(4, Math.max(0.3, this.baseScale * e.scale));
          this.onDirty();
        })
    )
    .parallelGesture(
      RotationGesture()
        .onActionStart(() => {
          this.onSelect();
          this.baseAngle = this.item.angleDeg;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.angleDeg = this.baseAngle + e.angle;
          this.onDirty();
        })
    )
  }
}

/**
 * StickerStudioPage —— 贴纸工作台（背景图 + 内置插图贴纸 → 合成壁纸）
 * ① 选背景（壁纸库 / 相册） → ② 多贴纸合成（拖拽 / 缩放 / 旋转 + 阴影 / 调色） → 导出
 *
 * 坐标约定：
 *  - UI / Canvas 绘制 / 触摸事件全部使用 vp
 *  - 贴纸 x, y 为「相对预览区中心的偏移」，便于跨 UI 与导出对齐
 *  - 导出画布与预览区同尺寸（vp），getPixelMap 按 vp 捕获、自动出物理分辨率
 */
@Component
export struct StickerStudioPage {
  onClose: () => void = () => {};

  // ===== 阶段与数据 =====
  @State stage: number = Stage.PickBg;
  @State wallpapers: Wallpaper[] = [];
  // 背景图源：本地 $r 资源 / 网络 URL / 相册 uri（Image 组件直接渲染，
  // 不要用 PixelMap——componentSnapshot 对 PixelMap 源截图会丢背景）
  @State bgSrc: ResourceStr | undefined = undefined;
  // 贴纸列表
  @State stickers: StudioSticker[] = [];
  @State selectedIdx: number = -1;

  // ===== 阴影 =====
  @State shadowEnabled: boolean = true;
  @State shadowOpacity: number = 0.3;
  @State shadowBlur: number = 8;
  @State shadowOffsetX: number = 0;
  @State shadowOffsetY: number = 4;

  // ===== 调色 =====
  @State colorBrightness: number = 0;
  @State colorContrast: number = 0;
  @State colorWarmth: number = 0;

  // ===== 面板 =====
  @State composePanel: string = 'stickers'; // 'stickers'|'shadow'|'color'
  @State panelCollapsed: boolean = false;    // 底部面板是否收起（收起后预览区最大化）
  @State saving: boolean = false;

  // ===== 导出框（即最终保存范围） =====
  @State exportRatio: string = '9:16';    // 'free' | '9:16' | '1:1' | '3:4'
  @State availW: number = 360;            // 预览区可用尺寸（vp）
  @State availH: number = 640;
  @State compW: number = 360;             // 导出框实际尺寸（vp）
  @State compH: number = 640;

  // ===== 手势基准（页面级，供 onStickerPan/Pinch/Rotate 使用） =====
  private baseX: number = 0;
  private baseY: number = 0;
  private baseScale: number = 1;
  private baseAngle: number = 0;

  // ===== 贴纸 ID 自增 =====
  private nextStickerId: number = 1;

  // ===== 背景变换（框内自由取景：双指缩放 / 单指拖动） =====
  @State bgScale: number = 1;
  @State bgOffsetX: number = 0;
  @State bgOffsetY: number = 0;
  private baseBgScale: number = 1;
  private baseBgX: number = 0;
  private baseBgY: number = 0;
  // 导出时是否包含背景（导出透明 PNG 时临时隐藏背景和色温层）
  @State exportBgVisible: boolean = true;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  aboutToAppear(): void {
    // 工作台是覆盖层：返回键先回"选背景"阶段，已在选背景阶段才问"是否放弃"
    this.backId = EditGuard.push((): boolean => {
      this.requestBack();
      return true;
    });
    this.loadData();
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
  }

  /**
   * 请求返回（顶栏 ‹ 与系统返回键共用）
   *  - 合成阶段 → 回到选背景阶段（贴纸仍在，不算丢失，无需确认）
   *  - 选背景阶段 → 退出；若已经贴过贴纸则先确认，避免辛苦摆好的图白白丢掉
   */
  private async requestBack(): Promise<void> {
    if (this.stage === Stage.Compose) {
      this.stage = Stage.PickBg;
      return;
    }
    if (this.stickers.length > 0) {
      const discard: boolean = await EditGuard.confirmDiscard();
      if (!discard) {
        return;
      }
    }
    this.onClose();
  }

  /** 加载壁纸库（云端优先，本地兜底） */
  async loadData(): Promise<void> {
    this.wallpapers = await CloudDBUtil.syncDefaultsIfEmpty();
  }

  /** 壁纸本地资源（无则 undefined） */
  private localOf(item: Wallpaper): Resource | undefined {
    return DefaultWallpapers.getLocalImg(item.id);
  }

  // ==================== ① 选背景 ====================

  /** 从壁纸库选背景 → 设 bgSrc（本地资源或网络 URL）+ 进入合成阶段 */
  pickBg(item: Wallpaper): void {
    const local: Resource | undefined = this.localOf(item);
    if (local !== undefined) {
      this.bgSrc = local;
    } else if (item.imageUrl.length > 0) {
      // Image 组件支持直接加载网络 URL（已声明 INTERNET 权限）
      this.bgSrc = item.imageUrl;
    } else {
      promptAction.showToast({ message: '背景加载失败' });
      return;
    }
    this.stickers = [];
    this.selectedIdx = -1;
    this.resetBgTransform();
    this.stage = Stage.Compose;
  }

  /** 从相册选背景（PhotoViewPicker 系统选择器，无需权限） */
  async pickBgFromAlbum(): Promise<void> {
    try {
      const p: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const res: picker.PhotoSelectResult = await p.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (res.photoUris.length > 0) {
        this.bgSrc = res.photoUris[0];
        this.stickers = [];
        this.selectedIdx = -1;
        this.resetBgTransform();
        this.stage = Stage.Compose;
      }
    } catch (e) {
      console.error(`pickBgFromAlbum failed: ${JSON.stringify(e)}`);
    }
  }

  // ==================== 贴纸操作 ====================

  /** 添加一张贴纸到画布中心附近（轻微错位避免完全重叠） */
  private addSticker(resName: string): void {
    const s: StudioSticker = new StudioSticker(this.nextStickerId++, resName);
    s.x = (this.stickers.length % 5) * 18 - 36;
    s.y = (this.stickers.length % 5) * 18 - 36;
    s.selected = true;
    // 取消其他贴纸选中
    for (const it of this.stickers) {
      it.selected = false;
    }
    const list: StudioSticker[] = [];
    for (const it of this.stickers) {
      list.push(it);
    }
    list.push(s);
    this.stickers = list;
    this.selectedIdx = list.length - 1;
  }

  /** 选中指定贴纸（取消其他选中） */
  private selectSticker(idx: number): void {
    for (let i = 0; i < this.stickers.length; i++) {
      this.stickers[i].selected = (i === idx);
    }
    this.selectedIdx = idx;
  }

  /** 删除当前选中的贴纸 */
  private removeSelected(): void {
    if (this.selectedIdx < 0) {
      promptAction.showToast({ message: '请先点选一张贴纸' });
      return;
    }
    const list: StudioSticker[] = [];
    for (let i = 0; i < this.stickers.length; i++) {
      if (i !== this.selectedIdx) {
        list.push(this.stickers[i]);
      }
    }
    this.stickers = list;
    this.selectedIdx = -1;
  }

  // ==================== 手势回调（页面级） ====================

  /** 拖动选中贴纸（基准值需在手势开始时设置） */
  onStickerPan(e: GestureEvent): void {
    if (this.selectedIdx < 0) {
      return;
    }
    const s: StudioSticker = this.stickers[this.selectedIdx];
    s.x = this.baseX + e.offsetX;
    s.y = this.baseY + e.offsetY;
  }

  /** 缩放选中贴纸 */
  onStickerPinch(e: GestureEvent): void {
    if (this.selectedIdx < 0) {
      return;
    }
    const s: StudioSticker = this.stickers[this.selectedIdx];
    s.scale = Math.min(4, Math.max(0.3, this.baseScale * e.scale));
  }

  /** 旋转选中贴纸 */
  onStickerRotate(e: GestureEvent): void {
    if (this.selectedIdx < 0) {
      return;
    }
    const s: StudioSticker = this.stickers[this.selectedIdx];
    s.angleDeg = this.baseAngle + e.angle;
  }

  // ==================== ② 合成导出 ====================

  /** 导出比例对应的宽高比（宽/高）；free 返回 0 */
  private ratioValue(): number {
    if (this.exportRatio === '1:1') {
      return 1;
    }
    if (this.exportRatio === '3:4') {
      return 3 / 4;
    }
    if (this.exportRatio === '9:16') {
      return 9 / 16;
    }
    return 0;
  }

  /** 根据可用区域和所选比例，计算导出框实际尺寸（contain 在可用区内） */
  private updateBoxSize(): void {
    const r: number = this.ratioValue();
    if (r === 0 || this.availH <= 0 || this.availW <= 0) {
      this.compW = this.availW;
      this.compH = this.availH;
      return;
    }
    let w: number = this.availW;
    let h: number = w / r;
    if (h > this.availH) {
      h = this.availH;
      w = h * r;
    }
    this.compW = Math.floor(w);
    this.compH = Math.floor(h);
  }

  // ==================== 背景取景（缩放 / 拖动 / 复位） ====================

  /** 背景变换矩阵：缩放后以框中心为锚点，再叠加拖动偏移 */
  private bgMatrix(): matrix4.Matrix4Transit {
    return matrix4.identity()
      .translate({ x: this.bgOffsetX, y: this.bgOffsetY, z: 0 })
      .translate({ x: this.compW / 2, y: this.compH / 2, z: 0 })
      .scale({ x: this.bgScale, y: this.bgScale, z: 1 })
      .translate({ x: -this.compW / 2, y: -this.compH / 2, z: 0 });
  }

  /** 拖动背景（触摸点在空白处才会触发，贴纸优先响应贴纸手势） */
  onBgPanStart(): void {
    this.baseBgX = this.bgOffsetX;
    this.baseBgY = this.bgOffsetY;
  }

  onBgPanUpdate(e: GestureEvent): void {
    const maxX: number = (this.bgScale - 1) * this.compW / 2;
    const maxY: number = (this.bgScale - 1) * this.compH / 2;
    this.bgOffsetX = Math.max(-maxX, Math.min(maxX, this.baseBgX + e.offsetX));
    this.bgOffsetY = Math.max(-maxY, Math.min(maxY, this.baseBgY + e.offsetY));
  }

  onBgPinchStart(): void {
    this.baseBgScale = this.bgScale;
  }

  onBgPinchUpdate(e: GestureEvent): void {
    this.bgScale = Math.max(1, Math.min(4, this.baseBgScale * e.scale));
    // 缩放后收紧偏移，防止露出空边
    const maxX: number = (this.bgScale - 1) * this.compW / 2;
    const maxY: number = (this.bgScale - 1) * this.compH / 2;
    this.bgOffsetX = Math.max(-maxX, Math.min(maxX, this.bgOffsetX));
    this.bgOffsetY = Math.max(-maxY, Math.min(maxY, this.bgOffsetY));
  }

  /** 背景取景复位 */
  resetBgTransform(): void {
    this.bgScale = 1;
    this.bgOffsetX = 0;
    this.bgOffsetY = 0;
  }

  /** 调整当前选中贴纸的大小（面板滑杆） */
  onSelectedScaleChange(v: number): void {
    if (this.selectedIdx >= 0 && this.selectedIdx < this.stickers.length) {
      this.stickers[this.selectedIdx].scale = v;
    }
  }

  /**
   * 导出并保存 —— 直接对预览组件截图（componentSnapshot），所见即所得：
   * 背景取景 / 贴纸位置大小 / 阴影 / 调色 全部是屏幕渲染结果，零坐标换算。
   *  - ALBUM_JPG：SaveButton 临时授权 + JPG 存系统相册
   *  - ALBUM_PNG：临时隐藏背景 → 截图得到透明底 PNG 存系统相册
   *  - SET_LOCK / SET_HOME：保存 JPG 到相册 + 弹窗引导去图库设为壁纸
   *    （四个入口都必须是 SaveButton，普通点击没有临时写相册授权）
   */
  async save(target: number): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    // 先取消选中，避免选中虚线框被截进成品图
    this.selectedIdx = -1;
    for (const it of this.stickers) {
      it.selected = false;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 250);
      });
      // PNG：临时隐藏背景 + 色温层，得到透明底
      if (target === SaveTarget.ALBUM_PNG) {
        this.exportBgVisible = false;
        await new Promise<void>((resolve) => {
          setTimeout(() => resolve(), 250);
        });
      }
      // 直接截图预览内容区（id = studioContent）
      const pm: image.PixelMap = await componentSnapshot.get('studioContent');
      this.exportBgVisible = true;

      const packer: image.ImagePacker = image.createImagePacker();
      // 导出用的沙箱临时文件路径（此前这些文件从不删除，会一直堆在 filesDir）
      let tempPath: string = '';
      // 截图位图与打包器都是 Native 资源，必须显式释放：
      // 此前每导出一次就泄漏一张全尺寸截图 + 一个 packer（GC 不回收）。
      try {
        if (target === SaveTarget.ALBUM_PNG) {
          // 透明 PNG 存相册
          const pngBuf: ArrayBuffer = await packer.packing(pm, { format: 'image/png', quality: 100 });
          const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
          const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
          const f = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
          fileIo.writeSync(f.fd, pngBuf);
          fileIo.closeSync(f);
          promptAction.showToast({ message: '透明PNG已保存到相册 ✅' });
        } else if (target === SaveTarget.SET_LOCK || target === SaveTarget.SET_HOME) {
          // ===== 存为锁屏 / 桌面壁纸用图 =====
          // @ohos.wallpaper 自 API 9 起废弃，HarmonyOS NEXT 不允许三方应用直接换壁纸。
          // 正确做法：保存 JPG 到相册 + 引导用户去系统图库设置。
          // 文案统一由 SetWallpaperGuide 产出，与首页大图预览保持完全一致。
          const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 95 });
          const dest: string = `${ctx.filesDir}/zeroone_wallpaper_${Date.now()}.jpg`;
          tempPath = dest;
          const wf = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
          fileIo.writeSync(wf.fd, buf);
          fileIo.closeSync(wf);
          const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
          const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
          const f2 = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
          fileIo.copyFileSync(dest, f2.fd);
          fileIo.closeSync(f2);
          const kind: number = target === SaveTarget.SET_LOCK ? WallpaperKind.LOCK : WallpaperKind.HOME;
          await showSetWallpaperDialog(kind);
        } else {
          // JPG 存相册
          const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 95 });
          const dest: string = `${ctx.filesDir}/zeroone_export_${Date.now()}.jpg`;
          tempPath = dest;
          const f = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
          fileIo.writeSync(f.fd, buf);
          fileIo.closeSync(f);
          // 存系统相册（SaveButton 临时授权下无需声明权限）
          const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
          const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
          const f2 = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
          fileIo.copyFileSync(dest, f2.fd);
          fileIo.closeSync(f2);
          promptAction.showToast({ message: '已保存到相册 ✅' });
        }
      } finally {
        PixelScope.safeRelease(pm);
        try {
          packer.release();
        } catch (e) {
          console.error(`release packer failed: ${JSON.stringify(e)}`);
        }
        // 拷贝进相册后删除沙箱临时文件
        if (tempPath.length > 0) {
          try {
            fileIo.unlinkSync(tempPath);
          } catch (e) {
            // 忽略：文件可能已被清理
          }
        }
      }
    } catch (e) {
      console.error(`save failed: ${JSON.stringify(e)}`);
      this.exportBgVisible = true;
      // 透出真实错误码，便于定位（权限/能力问题不再被“请重试”掩盖）
      const err: BusinessError = e as BusinessError;
      promptAction.showToast({
        message: err && err.code !== undefined ? `设置失败（错误码 ${err.code}）` : '保存失败，请重试'
      });
    } finally {
      this.saving = false;
    }
  }

  @Builder
  header(title: string) {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor('#FF6B6B')
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          // 统一走 requestBack：合成阶段回选背景，退出前按需确认
          this.requestBack();
        })
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text(`${this.stickers.length} 张`)
        .fontSize(12)
        .fontColor('#7A7A85')
        .width(70)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ top: 10, bottom: 6, left: 8, right: 12 })
  }

  build() {
    Stack() {
      Column() {
        this.header('贴纸工作台')

        if (this.stage === Stage.PickBg) {
          // ===== ① 选背景 =====
          Column() {
            Text('① 选择一张背景图')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
              .width('100%')
              .padding({ left: 16, bottom: 8 })
            Row({ space: 10 }) {
              Text('📷 从相册选')
                .fontSize(13)
                .fontColor('#FF6B6B')
                .backgroundColor('#3A2530')
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(14)
                .onClick(() => {
                  this.pickBgFromAlbum();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ bottom: 8 })

            Grid() {
              ForEach(this.wallpapers, (item: Wallpaper) => {
                GridItem() {
                  Column() {
                    Stack() {
                      if (this.localOf(item) !== undefined) {
                        Image(this.localOf(item))
                          .width('100%').height('100%').objectFit(ImageFit.Cover)
                      } else if (item.imageUrl.length > 0) {
                        Image(item.imageUrl)
                          .width('100%').height('100%').objectFit(ImageFit.Cover)
                      }
                    }
                    .width('100%')
                    .aspectRatio(0.75)
                    .clip(true)
                    .borderRadius(10)
                    .backgroundColor('#1C1D22')
                    Text(item.category)
                      .fontSize(11)
                      .fontColor('#7A7A85')
                      .margin({ top: 4 })
                  }
                  .width('100%')
                  .onClick(() => {
                    this.pickBg(item);
                  })
                }
              }, (item: Wallpaper) => item.id)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(10)
            .padding({ left: 12, right: 12, bottom: 12 })
            .layoutWeight(1)
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          // ===== ② 合成 =====
          Column() {
            // 导出中提示：截图+编码需要时间，给出明确反馈（此前点了完全没反应）
            if (this.saving) {
              Row({ space: 6 }) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color('#FF6B6B')
                Text('正在导出，请稍候…')
                  .fontSize(11)
                  .fontColor('#9A9AA5')
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 4 })
            }

            // 紧凑工具栏：存JPG / 存PNG / 锁屏 / 桌面，四等分一行
            Row({ space: 8 }) {
              // 存 JPG（必须使用 SaveButton 安全控件：点击瞬间由系统授予写相册临时授权）
              Column({ space: 2 }) {
                SaveButton({
                  icon: SaveIconStyle.FULL_FILLED,
                  buttonType: ButtonType.Capsule
                })
                  .width('100%')
                  .height(32)
                  // 导出中禁用：防止连点产生多张重复相册图
                  // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
                  .enabled(!this.saving)
                  .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result === SaveButtonOnClickResult.SUCCESS) {
                      this.save(SaveTarget.ALBUM_JPG);
                    }
                  })
                Text('存 JPG')
                  .fontSize(9)
                  .fontColor('#7A7A85')
              }
              .layoutWeight(1)

              // 存透明 PNG（同样必须用 SaveButton）
              Column({ space: 2 }) {
                SaveButton({
                  icon: SaveIconStyle.FULL_FILLED,
                  buttonType: ButtonType.Capsule
                })
                  .width('100%')
                  .height(32)
                  // 导出中禁用：防止连点产生多张重复相册图
                  // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
                  .enabled(!this.saving)
                  .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result === SaveButtonOnClickResult.SUCCESS) {
                      this.save(SaveTarget.ALBUM_PNG);
                    }
                  })
                Text('透明 PNG')
                  .fontSize(9)
                  .fontColor('#7A7A85')
              }
              .layoutWeight(1)

              // 存为锁屏用图（必须用 SaveButton：普通 Text 点击没有临时写相册授权，
              // 下一步的 createAsset 会直接抛权限错误——真机上必现）
              Column({ space: 2 }) {
                SaveButton({
                  icon: SaveIconStyle.FULL_FILLED,
                  buttonType: ButtonType.Capsule
                })
                  .width('100%')
                  .height(32)
                  // 导出中禁用：防止连点产生多张重复相册图
                  // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
                  .enabled(!this.saving)
                  .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result === SaveButtonOnClickResult.SUCCESS) {
                      this.save(SaveTarget.SET_LOCK);
                    }
                  })
                Text('锁屏图')
                  .fontSize(9)
                  .fontColor('#7A7A85')
              }
              .layoutWeight(1)

              // 存为桌面用图（同样必须用 SaveButton）
              Column({ space: 2 }) {
                SaveButton({
                  icon: SaveIconStyle.FULL_FILLED,
                  buttonType: ButtonType.Capsule
                })
                  .width('100%')
                  .height(32)
                  // 导出中禁用：防止连点产生多张重复相册图
                  // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
                  .enabled(!this.saving)
                  .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
                    if (result === SaveButtonOnClickResult.SUCCESS) {
                      this.save(SaveTarget.SET_HOME);
                    }
                  })
                Text('桌面图')
                  .fontSize(9)
                  .fontColor('#7A7A85')
              }
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 6, bottom: 2 })

            // 导出比例（细行，决定白框即保存范围的宽高比）
            Row({ space: 6 }) {
              Text('比例')
                .fontSize(10)
                .fontColor('#5C5C66')
                .margin({ right: 2 })
              ForEach(['free', '9:16', '1:1', '3:4'], (r: string) => {
                Text(r === 'free' ? '自由' : r)
                  .fontSize(11)
                  .fontColor(this.exportRatio === r ? Color.White : '#7A7A85')
                  .backgroundColor(this.exportRatio === r ? '#FF6B6B' : '#1C1D22')
                  .padding({ left: 12, right: 12, top: 3, bottom: 3 })
                  .borderRadius(10)
                  .onClick(() => {
                    this.exportRatio = r;
                    this.updateBoxSize();
                  })
              }, (r: string) => r)
              Blank()
              Text('做壁纸选 9:16')
                .fontSize(9)
                .fontColor('#5C5C66')
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 4 })

            // 预览区（外层=可用区域，深色底；白框=导出范围，框内内容截图保存）
            Stack() {
              // ===== 内容层（id=studioContent，保存时直接截图，所见即所得） =====
              Stack() {
                if (this.exportBgVisible && this.bgSrc !== undefined) {
                  Image(this.bgSrc)
                    .width('100%').height('100%').objectFit(ImageFit.Cover)
                    .brightness(1 + this.colorBrightness)
                    .contrast(1 + this.colorContrast)
                    .transform(this.bgMatrix())
                }
                ForEach(this.stickers, (s: StudioSticker) => {
                  StickerNode({
                    item: s,
                    canvasW: this.compW,
                    canvasH: this.compH,
                    shadowEnabled: this.shadowEnabled,
                    shadowOpacity: this.shadowOpacity,
                    shadowBlur: this.shadowBlur,
                    shadowOffsetX: this.shadowOffsetX,
                    shadowOffsetY: this.shadowOffsetY,
                    imgBrightness: this.colorBrightness,
                    imgContrast: this.colorContrast,
                    onSelect: () => {
                      // 闭包捕获 s（稳定对象引用），动态查找当前下标，避免数组重排后 idx 失效
                      const idx: number = this.stickers.indexOf(s);
                      if (idx >= 0) {
                        this.selectSticker(idx);
                      }
                    },
                    onDirty: () => {
                    }
                  })
                }, (s: StudioSticker) => s.id.toString())

                // 色温叠加层（暖=橙 / 冷=蓝，半透明覆盖整框；导出透明 PNG 时隐藏）
                if (this.exportBgVisible && this.colorWarmth !== 0) {
                  Column()
                    .width('100%')
                    .height('100%')
                    .backgroundColor(this.colorWarmth > 0
                      ? `rgba(255,150,60,${this.colorWarmth * 0.25})`
                      : `rgba(70,130,255,${-this.colorWarmth * 0.25})`)
                    .hitTestBehavior(HitTestMode.None)
                }
              }
              .id('studioContent')
              .width(this.compW)
              .height(this.compH)
              .clip(true)
              .backgroundColor('#191A1F')

              // ===== 框饰层（不进截图）：白框 + 范围提示 + 删除按钮 =====
              Stack() {
                Column()
                  .width('100%')
                  .height('100%')
                  .border({ width: 2, color: Color.White })
                  .borderRadius(4)
                  .hitTestBehavior(HitTestMode.None)
                Text('📷 白色边框内即保存范围 · 空白处可拖动/双指缩放背景')
                  .fontSize(10)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(0,0,0,0.55)')
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(10)
                  .position({ x: '50%', y: 8 })
                  .markAnchor({ x: '50%', y: 0 })
                  .hitTestBehavior(HitTestMode.None)
                // 选中贴纸的删除角标
                if (this.selectedIdx >= 0) {
                  Text('🗑')
                    .fontSize(14)
                    .width(34)
                    .height(34)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('#FF6B6B')
                    .borderRadius(17)
                    .position({ x: '50%', y: '92%' })
                    .markAnchor({ x: '50%', y: '100%' })
                    .onClick(() => {
                      this.removeSelected();
                    })
                }
              }
              .width(this.compW)
              .height(this.compH)
              .hitTestBehavior(HitTestMode.Transparent)
            }
            .width('100%')
            .layoutWeight(1)
            .backgroundColor('#0B0B0E')
            // 背景取景手势（触摸空白处生效；在贴纸上时贴纸手势优先）
            .gesture(
              GestureGroup(GestureMode.Parallel,
                PanGesture()
                  .onActionStart(() => {
                    this.onBgPanStart();
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onBgPanUpdate(e);
                  }),
                PinchGesture()
                  .onActionStart(() => {
                    this.onBgPinchStart();
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onBgPinchUpdate(e);
                  })
              )
            )
            .onClick(() => {
              // 点框外空白取消选中
              this.selectedIdx = -1;
              for (const it of this.stickers) {
                it.selected = false;
              }
            })
            .onAreaChange((_: Area, newValue: Area) => {
              this.availW = newValue.width as number;
              this.availH = newValue.height as number;
              this.updateBoxSize();
            })

            // ===== 面板头：Tab chips + 收起/展开开关 =====
            Row({ space: 8 }) {
              Text('🎭 贴纸')
                .fontSize(12)
                .fontColor(this.composePanel === 'stickers' ? Color.White : '#7A7A85')
                .backgroundColor(this.composePanel === 'stickers' ? '#FF6B6B' : '#1C1D22')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(14)
                .onClick(() => {
                  if (this.panelCollapsed) {
                    this.panelCollapsed = false;
                  }
                  this.composePanel = 'stickers';
                })
              Text('💡 阴影')
                .fontSize(12)
                .fontColor(this.composePanel === 'shadow' ? Color.White : '#7A7A85')
                .backgroundColor(this.composePanel === 'shadow' ? '#FF6B6B' : '#1C1D22')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(14)
                .onClick(() => {
                  if (this.panelCollapsed) {
                    this.panelCollapsed = false;
                  }
                  this.composePanel = 'shadow';
                })
              Text('🎨 调色')
                .fontSize(12)
                .fontColor(this.composePanel === 'color' ? Color.White : '#7A7A85')
                .backgroundColor(this.composePanel === 'color' ? '#FF6B6B' : '#1C1D22')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(14)
                .onClick(() => {
                  if (this.panelCollapsed) {
                    this.panelCollapsed = false;
                  }
                  this.composePanel = 'color';
                })
              Blank()
              Text(this.panelCollapsed ? '🔼 展开' : '🔽 收起')
                .fontSize(11)
                .fontColor('#9A9AA5')
                .backgroundColor('#1C1D22')
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .borderRadius(14)
                .onClick(() => {
                  this.panelCollapsed = !this.panelCollapsed;
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })

            // ===== Tab 面板内容（收起时整块隐藏，预览区最大化） =====
            if (!this.panelCollapsed) {
            if (this.composePanel === 'stickers') {
              Column() {
                // 素材库网格（5 列滚动）
                Scroll() {
                  Grid() {
                    ForEach(PET_STICKERS, (name: string) => {
                      GridItem() {
                        Image($r(`app.media.${name}`))
                          .width('100%')
                          .aspectRatio(1)
                          .objectFit(ImageFit.Contain)
                          .backgroundColor('#2A2B32')
                          .borderRadius(10)
                          .padding(6)
                          .onClick(() => {
                            this.addSticker(name);
                          })
                      }
                    }, (name: string) => name)
                  }
                  .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
                  .columnsGap(6)
                  .rowsGap(6)
                  .padding({ left: 12, right: 12, top: 4, bottom: 8 })
                }
                .scrollable(ScrollDirection.Vertical)
                .scrollBar(BarState.Auto)
                .width('100%')
                .height(150)
                .backgroundColor('#191A1F')

                // 选中贴纸的大小调节滑杆（双指缩放在小屏不灵敏时的兜底）
                if (this.selectedIdx >= 0 && this.selectedIdx < this.stickers.length) {
                  Row({ space: 10 }) {
                    Text('🐾 大小')
                      .fontSize(12)
                      .fontColor('#7A7A85')
                      .width(48)
                    Slider({
                      value: this.stickers[this.selectedIdx].scale,
                      min: 0.3,
                      max: 2.5,
                      step: 0.05
                    })
                      .layoutWeight(1)
                      .selectedColor('#FF6B6B')
                      .onChange((v: number) => {
                        this.onSelectedScaleChange(v);
                      })
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 8 })
                  .backgroundColor('#0F0F12')
                }

                // 删除/清空/背景复位操作行
                Row({ space: 10 }) {
                  Text('🗑 删除选中')
                    .fontSize(13)
                    .fontColor(Color.White)
                    .backgroundColor('#FF6B6B')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .borderRadius(14)
                    .onClick(() => {
                      this.removeSelected();
                    })
                  Text('🧹 清空')
                    .fontSize(13)
                    .fontColor('#9A9AA5')
                    .backgroundColor('#2A2B32')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .borderRadius(14)
                    .onClick(() => {
                      this.stickers = [];
                      this.selectedIdx = -1;
                    })
                  Text('🌄 背景复位')
                    .fontSize(13)
                    .fontColor('#9A9AA5')
                    .backgroundColor('#2A2B32')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .borderRadius(14)
                    .onClick(() => {
                      this.resetBgTransform();
                    })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 10, bottom: 6 })
                .backgroundColor('#0F0F12')

                Text('点贴纸选中（虚线框）· 单指拖动 / 双指旋转缩放 · 空白处拖动或双指缩放背景')
                  .fontSize(11)
                  .fontColor('#7A7A85')
                  .padding({ bottom: 10 })
                  .backgroundColor('#0F0F12')
              }
              .width('100%')
            } else if (this.composePanel === 'shadow') {
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  Text('阴影')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(40)
                  Toggle({ type: ToggleType.Switch, isOn: this.shadowEnabled })
                    .selectedColor('#FF6B6B')
                    .onChange((on: boolean) => {
                      this.shadowEnabled = on;
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('透明度')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.shadowOpacity, min: 0, max: 0.8, step: 0.05 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.shadowOpacity = v;
                    })
                  Text(`${Math.round(this.shadowOpacity * 100)}%`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('模糊度')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.shadowBlur, min: 0, max: 20, step: 1 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.shadowBlur = v;
                    })
                  Text(`${Math.round(this.shadowBlur)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('X偏移')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.shadowOffsetX, min: -20, max: 20, step: 1 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.shadowOffsetX = v;
                    })
                  Text(`${Math.round(this.shadowOffsetX)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('Y偏移')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.shadowOffsetY, min: -20, max: 20, step: 1 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.shadowOffsetY = v;
                    })
                  Text(`${Math.round(this.shadowOffsetY)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
              }
              .width('100%')
              .padding({ top: 6, bottom: 10 })
            } else {
              // color
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  Text('亮度')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.colorBrightness, min: -0.5, max: 0.5, step: 0.05 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.colorBrightness = v;
                    })
                  Text(`${Math.round(this.colorBrightness * 100)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('对比度')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.colorContrast, min: -0.5, max: 0.5, step: 0.05 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.colorContrast = v;
                    })
                  Text(`${Math.round(this.colorContrast * 100)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('色温')
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(48)
                  Slider({ value: this.colorWarmth, min: -0.5, max: 0.5, step: 0.05 })
                    .layoutWeight(1)
                    .selectedColor('#FF6B6B')
                    .onChange((v: number) => {
                      this.colorWarmth = v;
                    })
                  Text(`${Math.round(this.colorWarmth * 100)}`)
                    .fontSize(12)
                    .fontColor('#7A7A85')
                    .width(36)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Row({ space: 10 }) {
                  Text('↺ 重置调色')
                    .fontSize(13)
                    .fontColor('#FF6B6B')
                    .backgroundColor('#3A2530')
                    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                    .borderRadius(14)
                    .onClick(() => {
                      this.colorBrightness = 0;
                      this.colorContrast = 0;
                      this.colorWarmth = 0;
                    })
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 4, bottom: 8 })
              }
              .width('100%')
              .padding({ top: 6, bottom: 10 })
            }
            }
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0F12')
    }
    .width('100%')
    .height('100%')
  }
}
