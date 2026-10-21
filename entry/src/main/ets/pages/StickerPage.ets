import { image } from '@kit.ImageKit';
import { componentSnapshot, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@ohos.base';
import { Wallpaper } from '../model/Wallpaper';
import { LocalWallpapers } from '../common/constants/LocalWallpapers';
import { WallpaperDataSource } from '../common/store/WallpaperDataSource';
import { showSetWallpaperDialog, WallpaperKind } from '../common/components/SetWallpaperGuide';
import { PixelScope } from '../common/utils/PixelScope';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import matrix4 from '@ohos.matrix4';

/**
 * StickerPage —— 贴纸 Tab =「贴纸专区」（统一编辑器）
 *
 * 由原「贴纸工作台 StickerStudioPage」与「贴纸画板 StickerBoardPage」二合一而来：
 * 两页能力高度重叠（同一份 51 张贴纸素材、同样的拖拽/缩放/旋转），
 * 画板只是工作台的子集，且 `saveBoard()` 有实现却没有任何 UI 调用点
 * —— 用户感知为「画板没有保存键」。合并后：
 *
 *  ① 选背景（内置壁纸库 / 相册，也可不选背景直接做透明 PNG）
 *  ② 贴贴纸（分类 + 收藏，拖拽 / 缩放 / 旋转 + 阴影 / 调色）
 *  ③ 导出（JPG / 透明 PNG / 锁屏图 / 桌面图）
 *
 * 相比原两页新增：三步引导条、统一底部工具栏、图层列表、撤销/重做、贴纸收藏。
 *
 * 坐标约定（与原工作台一致，勿改）：
 *  - UI / 触摸 / 导出全部使用 vp
 *  - 贴纸 x, y 为「相对画布中心的偏移」，与 ArkUI .transform(matrix4)
 *    的「原点 = 组件中心」约定对齐；位置用 .offset() 表达，transform 只做缩放旋转
 *  - 导出直接对画布内容层（id = stickerCanvas）截图，所见即所得
 */

/** 贴纸在画布上的基准边长（vp），UI 显示与导出绘制共用此值 */
const BASE_STICKER_SIZE: number = 140;

/** 撤销/重做历史上限 */
const HISTORY_MAX: number = 20;

/** 贴纸收藏的本地存储键 */
const KEY_STICKER_FAV: string = 'sticker_favorites';

/** 猫猫（31 张）：拉伸 / 纸箱 / 项圈 / 伸懒腰 / 玩毛线 / 睡觉 等姿态 */
const STICKERS_CAT: string[] = [
  'ot035_1', 'ot035_2', 'ot035_3', 'ot035_4', 'ot035_5',
  'ot093', 'ot093_1', 'ot093_2', 'ot093_3', 'ot093_4',
  'ot124', 'ot124_1', 'ot124_2', 'ot124_3', 'ot124_4',
  'ot305', 'ot305_1', 'ot305_2', 'ot305_3',
  'ot374', 'ot374_1', 'ot374_2', 'ot374_3',
  'ot375', 'ot375_1', 'ot375_2', 'ot375_3',
  'ot396', 'ot396_1', 'ot396_2', 'ot396_3'
];

/** 狗狗（16 张）：哈士奇 / 法斗 / 贵宾 / 各色坐姿 */
const STICKERS_DOG: string[] = [
  'ot288', 'ot288_1', 'ot288_2', 'ot288_3',
  'ot304', 'ot304_1', 'ot304_2', 'ot304_3',
  'ot355', 'ot355_1', 'ot355_2', 'ot355_3',
  'ot372', 'ot372_1', 'ot372_2', 'ot372_3'
];

/** 兔兔（4 张）：抱花小兔 */
const STICKERS_RABBIT: string[] = [
  'ot419', 'ot419_1', 'ot419_2', 'ot419_3'
];

/** 全部贴纸（51 张）—— 素材库唯一数据源 */
const STICKERS_ALL: string[] = STICKERS_CAT.concat(STICKERS_DOG).concat(STICKERS_RABBIT);

/** 贴纸分类（ArkTS 禁匿名对象数组，必须显式 interface + 常量） */
interface StickerCat {
  key: string;
  label: string;
}

const STICKER_CATS: StickerCat[] = [
  { key: 'all', label: '全部' },
  { key: 'cat', label: '猫猫' },
  { key: 'dog', label: '狗狗' },
  { key: 'rabbit', label: '兔兔' },
  { key: 'fav', label: '收藏' }
];

/** 底部工具栏面板（统一入口，取代原两页各自的 Tab） */
interface PanelTab {
  key: string;
  label: string;
}

const PANEL_TABS: PanelTab[] = [
  { key: 'background', label: '🖼 背景' },
  { key: 'sticker', label: '🐾 贴纸' },
  { key: 'layer', label: '🗂 图层' },
  { key: 'adjust', label: '🎛 调整' },
  { key: 'export', label: '📤 导出' }
];

/** 导出目标 */
enum SaveTarget {
  ALBUM_JPG = 0,    // 保存 JPG 到相册
  ALBUM_PNG = 1,    // 保存透明 PNG 到相册
  SET_LOCK = 2,     // 存为锁屏壁纸用图（保存后引导去图库设置）
  SET_HOME = 3      // 存为桌面壁纸用图（保存后引导去图库设置）
}

interface ExportTargetItem {
  t: number;
  label: string;
}

const EXPORT_TARGETS: ExportTargetItem[] = [
  { t: SaveTarget.ALBUM_JPG, label: '存 JPG' },
  { t: SaveTarget.ALBUM_PNG, label: '透明 PNG' },
  { t: SaveTarget.SET_LOCK, label: '锁屏图' },
  { t: SaveTarget.SET_HOME, label: '桌面图' }
];

const EXPORT_RATIOS: string[] = ['free', '9:16', '1:1', '3:4'];

/**
 * 画布上的贴纸：@Observed 使字段修改能被 @ObjectLink 子组件感知
 *  - x, y：贴纸中心相对画布中心的偏移（vp）
 *  - scale：缩放（0.3 ~ 4.0）
 *  - angleDeg：旋转角度（度，绕贴纸中心）
 */
@Observed
class StudioSticker {
  id: number = 0;
  resName: string = '';
  x: number = 0;
  y: number = 0;
  scale: number = 1;
  angleDeg: number = 0;

  constructor(id: number, resName: string) {
    this.id = id;
    this.resName = resName;
  }
}

/** 单张贴纸的快照（撤销/重做用，纯数据） */
class StickerSnap {
  resName: string = '';
  x: number = 0;
  y: number = 0;
  scale: number = 1;
  angleDeg: number = 0;

  constructor(resName: string, x: number, y: number, scale: number, angleDeg: number) {
    this.resName = resName;
    this.x = x;
    this.y = y;
    this.scale = scale;
    this.angleDeg = angleDeg;
  }
}

/** 编辑器完整状态快照：背景取景 + 阴影 + 调色 + 全部贴纸 */
class EditorSnap {
  bgKind: number = 0;
  bgKey: string = '';
  bgScale: number = 1;
  bgX: number = 0;
  bgY: number = 0;
  shadowEnabled: boolean = true;
  shadowOpacity: number = 0.3;
  shadowBlur: number = 8;
  shadowOffsetX: number = 0;
  shadowOffsetY: number = 4;
  colorB: number = 0;
  colorC: number = 0;
  colorW: number = 0;
  stickers: StickerSnap[] = [];
}

/**
 * 单张贴纸节点：@ObjectLink 观察 + Pan/Pinch/Rotation 手势 + 虚线选中框 + 删除角标
 *  - 手势直接修改 item 字段（x/y/scale/angleDeg），由 @Observed 推送 UI 刷新
 *  - selected 由父组件按 id 比对下发（跨撤销/重做重建数组后依然正确）
 *  - onCommit 在每次手势结束时回调，供父组件入撤销栈
 */
@Component
struct StickerNode {
  @ObjectLink item: StudioSticker;
  @Prop selected: boolean = false;
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
  onCommit: () => void = () => {};
  onDelete: () => void = () => {};

  private readonly baseSize: number = BASE_STICKER_SIZE;
  private baseX: number = 0;
  private baseY: number = 0;
  private baseScale: number = 1;
  private baseAngle: number = 0;

  /**
   * 缩放/旋转矩阵（原点 = 组件中心）。
   * 位置用 .offset(item.x, item.y) 表达，transform 只做绕中心的缩放/旋转 ——
   * 各向同性缩放与旋转可交换，链式乘序不影响结果。
   */
  private m(): matrix4.Matrix4Transit {
    return matrix4.identity()
      .scale({ x: this.item.scale, y: this.item.scale, z: 1 })
      .rotate({ x: 0, y: 0, z: 1, angle: this.item.angleDeg });
  }

  /**
   * 把贴纸中心夹在画布内（留 12vp 边距）：允许边缘出血（构图需要），
   * 但保证它始终有一部分留在框内、可被再次点中拖回。
   */
  private clampX(v: number): number {
    const lim: number = Math.max(0, this.canvasW / 2 - 12);
    return Math.max(-lim, Math.min(lim, v));
  }

  private clampY(v: number): number {
    const lim: number = Math.max(0, this.canvasH / 2 - 12);
    return Math.max(-lim, Math.min(lim, v));
  }

  /** 删除角标的反向缩放：贴纸缩到 0.4 倍时角标仍保持可点尺寸 */
  private badgeScale(): number {
    return this.item.scale > 0 ? 1 / this.item.scale : 1;
  }

  build() {
    Stack() {
      // 投影层：同一张图染黑（colorFilter 矩阵 RGB 全输出 0、保留 alpha）+ 模糊 + 透明度 + 偏移
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
      if (this.selected) {
        Column()
          .width(this.baseSize)
          .height(this.baseSize)
          .border({ width: 1.5, color: '#C9333D', style: BorderStyle.Dashed })
          .borderRadius(6)
          .hitTestBehavior(HitTestMode.None)
      }
      // 删除角标：挂在贴纸自己身上（跟着走），反向缩放保持点击尺寸恒定、反向旋转保持正立
      if (this.selected) {
        Text('🗑')
          .fontSize(13)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor('#C9333D')
          .borderRadius(15)
          .offset({ x: this.baseSize / 2 - 18, y: -this.baseSize / 2 + 18 })
          .scale({ x: this.badgeScale(), y: this.badgeScale() })
          .rotate({ angle: -this.item.angleDeg })
          .onClick(() => {
            this.onDelete();
          })
      }
    }
    .width(this.baseSize)
    .height(this.baseSize)
    .offset({ x: this.item.x, y: this.item.y })
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
          this.item.x = this.clampX(this.baseX + e.offsetX);
          this.item.y = this.clampY(this.baseY + e.offsetY);
          this.onDirty();
        })
        .onActionEnd(() => {
          this.onCommit();
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
        .onActionEnd(() => {
          this.onCommit();
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
        .onActionEnd(() => {
          this.onCommit();
        })
    )
  }
}

/**
 * StickerPage —— 贴纸专区（统一编辑器）
 * 背景 + 贴纸 → 合成导出；交互见文件头注释。
 */
@Component
export struct StickerPage {
  // ==================== 背景 ====================
  /** 0 无背景 / 1 内置壁纸 / 2 相册照片 */
  @State bgKind: number = 0;
  /** 背景标识：内置壁纸为 Wallpaper.id，相册为 uri（撤销/重做可还原） */
  @State bgKey: string = '';
  /** 背景可直接渲染的图源（由 bgKind/bgKey 派生，见 applyBg） */
  @State bgSrc: ResourceStr | undefined = undefined;
  @State bgScale: number = 1;
  @State bgOffsetX: number = 0;
  @State bgOffsetY: number = 0;

  // ==================== 贴纸 ====================
  @State stickers: StudioSticker[] = [];
  /** 当前选中贴纸 id（-1 = 无） */
  @State selectedId: number = -1;
  /**
   * 贴纸手势/滑杆改动自增：item 是 @Observed，只刷新 @ObjectLink 的 StickerNode，
   * 父组件里依赖贴纸位置/大小的滑杆浮层需读此 tick 才会随之重绘。
   */
  @State transformTick: number = 0;
  private nextStickerId: number = 1;

  // ==================== 阴影 ====================
  @State shadowEnabled: boolean = true;
  @State shadowOpacity: number = 0.3;
  @State shadowBlur: number = 8;
  @State shadowOffsetX: number = 0;
  @State shadowOffsetY: number = 4;

  // ==================== 调色 ====================
  @State colorBrightness: number = 0;
  @State colorContrast: number = 0;
  @State colorWarmth: number = 0;

  // ==================== 面板 ====================
  @State panel: string = 'background';
  @State collapsed: boolean = false;
  @State saving: boolean = false;

  // ==================== 贴纸素材库 ====================
  @State activeCat: string = 'all';
  @State panelList: string[] = STICKERS_ALL;
  @State favNames: string[] = [];

  // ==================== 导出框（即最终保存范围） ====================
  @State exportRatio: string = '9:16';
  @State exportTarget: number = SaveTarget.ALBUM_JPG;
  @State availW: number = 360;
  @State availH: number = 640;
  @State compW: number = 360;
  @State compH: number = 640;
  /** 导出透明 PNG 时临时隐藏背景与色温层（画布内容层本身无底色，alpha 得以保留） */
  @State exportBgVisible: boolean = true;

  // ==================== 背景取景手势基准 ====================
  private baseBgScale: number = 1;
  private baseBgX: number = 0;
  private baseBgY: number = 0;

  // ==================== 撤销/重做 ====================
  private history: EditorSnap[] = [];
  /** 当前所处历史下标（-1 = 空栈） */
  @State histIndex: number = -1;
  /** 历史总长度（驱动按钮可用态） */
  @State histLen: number = 0;

  // ==================== 壁纸库（背景选择） ====================
  private ds: WallpaperDataSource = new WallpaperDataSource();
  private wallpapers: Wallpaper[] = [];

  private readonly stepLabels: string[] = ['① 选背景', '② 贴贴纸', '③ 导出'];

  aboutToAppear(): void {
    this.wallpapers = LocalWallpapers.ALL;
    this.ds.updateAll(this.wallpapers);
    this.favNames = this.loadFav();
    this.refreshPanelList();
    this.history = [];
    this.histIndex = -1;
    this.histLen = 0;
    this.commit(); // 初始快照：撤销不会越过这里
  }

  // ==================== 三步引导 ====================

  /**
   * 当前所处步骤：1 选背景 / 2 贴贴纸 / 3 导出
   * 有贴纸即视为已进入第 3 步（允许不选背景直接贴图做透明 PNG）
   */
  private currentStep(): number {
    if (this.stickers.length > 0) {
      return 3;
    }
    return this.bgKind === 0 ? 1 : 2;
  }

  // ==================== 背景 ====================

  /** 统一的背景状态入口：同步 bgKind / bgKey / bgSrc 三者，避免各写一份导致漂移 */
  private applyBg(kind: number, key: string): void {
    this.bgKind = kind;
    this.bgKey = key;
    if (kind === 1) {
      this.bgSrc = LocalWallpapers.getLocalImg(key);
    } else if (kind === 2) {
      this.bgSrc = key;
    } else {
      this.bgSrc = undefined;
    }
  }

  /** 从壁纸库选背景 */
  private pickLocalBg(item: Wallpaper): void {
    if (LocalWallpapers.getLocalImg(item.id) === undefined) {
      promptAction.showToast({ message: '背景加载失败' });
      return;
    }
    this.applyBg(1, item.id);
    this.resetBgTransform();
    this.panel = 'sticker'; // 引导进入第 ② 步
    this.commit(true);
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
        this.applyBg(2, res.photoUris[0]);
        this.resetBgTransform();
        this.panel = 'sticker';
        this.commit(true);
      }
    } catch (e) {
      console.error(`pickBgFromAlbum failed: ${JSON.stringify(e)}`);
    }
  }

  /** 移除背景（保留贴纸，可导出透明 PNG） */
  private clearBg(): void {
    this.applyBg(0, '');
    this.resetBgTransform();
    this.commit(true);
  }

  /** 背景取景缩放矩阵（原点 = 框中心），位移用 .offset 表达 */
  private bgMatrix(): matrix4.Matrix4Transit {
    return matrix4.identity()
      .scale({ x: this.bgScale, y: this.bgScale, z: 1 });
  }

  private onBgPanStart(): void {
    this.baseBgX = this.bgOffsetX;
    this.baseBgY = this.bgOffsetY;
  }

  private onBgPanUpdate(e: GestureEvent): void {
    const maxX: number = (this.bgScale - 1) * this.compW / 2;
    const maxY: number = (this.bgScale - 1) * this.compH / 2;
    this.bgOffsetX = Math.max(-maxX, Math.min(maxX, this.baseBgX + e.offsetX));
    this.bgOffsetY = Math.max(-maxY, Math.min(maxY, this.baseBgY + e.offsetY));
  }

  private onBgPinchStart(): void {
    this.baseBgScale = this.bgScale;
  }

  private onBgPinchUpdate(e: GestureEvent): void {
    this.bgScale = Math.max(1, Math.min(4, this.baseBgScale * e.scale));
    // 缩放后收紧偏移，防止露出空边
    const maxX: number = (this.bgScale - 1) * this.compW / 2;
    const maxY: number = (this.bgScale - 1) * this.compH / 2;
    this.bgOffsetX = Math.max(-maxX, Math.min(maxX, this.bgOffsetX));
    this.bgOffsetY = Math.max(-maxY, Math.min(maxY, this.bgOffsetY));
  }

  /** 背景取景复位 */
  private resetBgTransform(): void {
    this.bgScale = 1;
    this.bgOffsetX = 0;
    this.bgOffsetY = 0;
  }

  // ==================== 贴纸操作 ====================

  /**
   * 添加一张贴纸：按对角线级联依次落位（避免连续添加时叠在同一处）
   * 5 个落位循环，每级在 x / y 各偏移 SLOT，视觉上从左上到右下依次错开。
   */
  private addSticker(resName: string): void {
    const slotStep: number = 28;
    const s: StudioSticker = new StudioSticker(this.nextStickerId, resName);
    this.nextStickerId = this.nextStickerId + 1;
    const k: number = this.stickers.length % 5;
    const d: number = k - 2;
    s.x = d * slotStep;
    s.y = d * slotStep;
    const list: StudioSticker[] = [];
    for (const it of this.stickers) {
      list.push(it);
    }
    list.push(s);
    this.stickers = list;
    this.selectedId = s.id;
    this.commit(true);
  }

  /** 删除指定贴纸 */
  private removeSticker(id: number): void {
    const list: StudioSticker[] = [];
    for (const it of this.stickers) {
      if (it.id !== id) {
        list.push(it);
      }
    }
    this.stickers = list;
    if (this.selectedId === id) {
      this.selectedId = -1;
    }
    this.commit(true);
  }

  /** 删除当前选中的贴纸 */
  private removeSelected(): void {
    if (this.selectedId < 0) {
      promptAction.showToast({ message: '请先点选一张贴纸' });
      return;
    }
    this.removeSticker(this.selectedId);
  }

  private clearAll(): void {
    if (this.stickers.length === 0) {
      return;
    }
    this.stickers = [];
    this.selectedId = -1;
    this.commit(true);
  }

  private selectedSticker(): StudioSticker | undefined {
    for (const s of this.stickers) {
      if (s.id === this.selectedId) {
        return s;
      }
    }
    return undefined;
  }

  private selScale(): number {
    const s: StudioSticker | undefined = this.selectedSticker();
    return s === undefined ? 1 : s.scale;
  }

  /** 选中贴纸缩放滑杆的 y 坐标：贴纸下边缘下方 12vp，clamp 在画布内 */
  private stickerSliderY(): number {
    // 依赖 transformTick：手势/滑杆改贴纸大小或位置后强制重算
    const tick: number = this.transformTick;
    const s: StudioSticker | undefined = this.selectedSticker();
    if (s === undefined) {
      return 16 + (tick - tick);
    }
    const bottom: number = this.compH / 2 + s.y + (BASE_STICKER_SIZE * s.scale) / 2;
    return Math.max(16, Math.min(this.compH - 48, bottom + 12));
  }

  // ==================== 图层 / 贴纸库列表 ====================

  /** 图层列表：上层贴纸在前（数组尾部 = 后添加 = 更上层） */
  private layersTop(): StudioSticker[] {
    const out: StudioSticker[] = [];
    for (let i = this.stickers.length - 1; i >= 0; i--) {
      out.push(this.stickers[i]);
    }
    return out;
  }

  private isFav(name: string): boolean {
    return this.favNames.indexOf(name) >= 0;
  }

  /** 切换收藏（收藏分类下实时刷新列表） */
  private toggleFavP(name: string): void {
    const list: string[] = [];
    let removed: boolean = false;
    for (const n of this.favNames) {
      if (n === name) {
        removed = true;
      } else {
        list.push(n);
      }
    }
    if (!removed) {
      list.unshift(name);
    }
    this.favNames = list;
    PreferenceUtil.setString(KEY_STICKER_FAV, JSON.stringify(list));
    if (this.activeCat === 'fav') {
      this.refreshPanelList();
    }
  }

  /** 读取本地收藏（过滤掉已不存在的素材名） */
  private loadFav(): string[] {
    const raw: string = PreferenceUtil.getString(KEY_STICKER_FAV, '[]');
    try {
      const arr: string[] = JSON.parse(raw) as string[];
      const out: string[] = [];
      for (const n of arr) {
        if (STICKERS_ALL.indexOf(n) >= 0) {
          out.push(n);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private refreshPanelList(): void {
    if (this.activeCat === 'cat') {
      this.panelList = STICKERS_CAT;
    } else if (this.activeCat === 'dog') {
      this.panelList = STICKERS_DOG;
    } else if (this.activeCat === 'rabbit') {
      this.panelList = STICKERS_RABBIT;
    } else if (this.activeCat === 'fav') {
      this.panelList = this.favNames.slice();
    } else {
      this.panelList = STICKERS_ALL;
    }
  }

  // ==================== 撤销 / 重做 ====================

  /** 抓取当前完整状态 */
  private capture(): EditorSnap {
    const s: EditorSnap = new EditorSnap();
    s.bgKind = this.bgKind;
    s.bgKey = this.bgKey;
    s.bgScale = this.bgScale;
    s.bgX = this.bgOffsetX;
    s.bgY = this.bgOffsetY;
    s.shadowEnabled = this.shadowEnabled;
    s.shadowOpacity = this.shadowOpacity;
    s.shadowBlur = this.shadowBlur;
    s.shadowOffsetX = this.shadowOffsetX;
    s.shadowOffsetY = this.shadowOffsetY;
    s.colorB = this.colorBrightness;
    s.colorC = this.colorContrast;
    s.colorW = this.colorWarmth;
    const list: StickerSnap[] = [];
    for (const it of this.stickers) {
      list.push(new StickerSnap(it.resName, it.x, it.y, it.scale, it.angleDeg));
    }
    s.stickers = list;
    return s;
  }

  /** 状态指纹：用于同态去重，避免「点一下贴纸」也产生一条历史 */
  private describe(s: EditorSnap): string {
    let t: string = `${s.bgKind}|${s.bgKey}|${s.bgScale.toFixed(3)}|${s.bgX.toFixed(1)}|${s.bgY.toFixed(1)}`
      + `|${s.shadowEnabled}|${s.shadowOpacity.toFixed(2)}|${s.shadowBlur}|${s.shadowOffsetX}|${s.shadowOffsetY}`
      + `|${s.colorB.toFixed(2)}|${s.colorC.toFixed(2)}|${s.colorW.toFixed(2)}`;
    for (let i = 0; i < s.stickers.length; i++) {
      const k: StickerSnap = s.stickers[i];
      t += `#${k.resName},${k.x.toFixed(1)},${k.y.toFixed(1)},${k.scale.toFixed(3)},${k.angleDeg.toFixed(1)}`;
    }
    return t;
  }

  /**
   * 入栈一次编辑（在「一次操作结束」时调用）
   * @param force 结构性操作（增删贴纸 / 换背景）传 true：即使与当前历史同态也要截断重做尾巴
   */
  private commit(force: boolean = false): void {
    const s: EditorSnap = this.capture();
    if (!force && this.histIndex >= 0 && this.histIndex < this.history.length
      && this.describe(this.history[this.histIndex]) === this.describe(s)) {
      return;
    }
    const next: EditorSnap[] = [];
    for (let i = 0; i <= this.histIndex && i < this.history.length; i++) {
      next.push(this.history[i]);
    }
    next.push(s);
    while (next.length > HISTORY_MAX) {
      next.shift();
    }
    this.history = next;
    this.histIndex = next.length - 1;
    this.histLen = next.length;
  }

  /** 单入口还原：撤销与重做都走这里 */
  private applySnap(s: EditorSnap): void {
    this.applyBg(s.bgKind, s.bgKey);
    this.bgScale = s.bgScale;
    this.bgOffsetX = s.bgX;
    this.bgOffsetY = s.bgY;
    this.shadowEnabled = s.shadowEnabled;
    this.shadowOpacity = s.shadowOpacity;
    this.shadowBlur = s.shadowBlur;
    this.shadowOffsetX = s.shadowOffsetX;
    this.shadowOffsetY = s.shadowOffsetY;
    this.colorBrightness = s.colorB;
    this.colorContrast = s.colorC;
    this.colorWarmth = s.colorW;
    const list: StudioSticker[] = [];
    for (const k of s.stickers) {
      const it: StudioSticker = new StudioSticker(this.nextStickerId, k.resName);
      this.nextStickerId = this.nextStickerId + 1;
      it.x = k.x;
      it.y = k.y;
      it.scale = k.scale;
      it.angleDeg = k.angleDeg;
      list.push(it);
    }
    this.stickers = list;
    this.selectedId = -1;
    this.transformTick = this.transformTick + 1;
  }

  private undo(): void {
    if (this.histIndex <= 0) {
      return;
    }
    this.histIndex = this.histIndex - 1;
    this.applySnap(this.history[this.histIndex]);
  }

  private redo(): void {
    if (this.histIndex >= this.history.length - 1) {
      return;
    }
    this.histIndex = this.histIndex + 1;
    this.applySnap(this.history[this.histIndex]);
  }

  // ==================== 导出框 ====================

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
    const oldW: number = this.compW;
    const oldH: number = this.compH;
    const r: number = this.ratioValue();
    if (r === 0 || this.availH <= 0 || this.availW <= 0) {
      this.compW = Math.floor(this.availW);
      this.compH = Math.floor(this.availH);
    } else {
      let w: number = this.availW;
      let h: number = w / r;
      if (h > this.availH) {
        h = this.availH;
        w = h * r;
      }
      this.compW = Math.floor(w);
      this.compH = Math.floor(h);
    }
    // 框尺寸变化时按比例缩放贴纸位置，防止收起/展开面板时贴纸跳位
    if (oldW > 0 && oldH > 0 && this.stickers.length > 0) {
      const sx: number = this.compW / oldW;
      const sy: number = this.compH / oldH;
      for (const s of this.stickers) {
        s.x *= sx;
        s.y *= sy;
      }
    }
  }

  // ==================== 保存 ====================

  /**
   * 导出并保存 —— 直接对画布内容层（id = stickerCanvas）截图，所见即所得：
   * 背景取景 / 贴纸位置大小 / 阴影 / 调色 全是屏幕渲染结果，零坐标换算。
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
    // 先取消选中，避免选中虚线框/删除角标被截进成品图
    this.selectedId = -1;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 250);
      });
      if (target === SaveTarget.ALBUM_PNG) {
        this.exportBgVisible = false;
        await new Promise<void>((resolve) => {
          setTimeout(() => resolve(), 250);
        });
      }
      const pm: image.PixelMap = await componentSnapshot.get('stickerCanvas');
      this.exportBgVisible = true;

      const packer: image.ImagePacker = image.createImagePacker();
      // 导出用的沙箱临时文件路径（用完必须删，否则会一直堆在 filesDir）
      let tempPath: string = '';
      // 截图位图与打包器都是 Native 资源，必须显式释放
      try {
        if (target === SaveTarget.ALBUM_PNG) {
          const pngBuf: ArrayBuffer = await packer.packing(pm, { format: 'image/png', quality: 100 });
          const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
          const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
          const f = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
          fileIo.writeSync(f.fd, pngBuf);
          fileIo.closeSync(f);
          promptAction.showToast({ message: '透明PNG已保存到相册 ✅' });
        } else if (target === SaveTarget.SET_LOCK || target === SaveTarget.SET_HOME) {
          // @ohos.wallpaper 自 API 9 起废弃，三方应用不能直接换壁纸：
          // 保存 JPG 到相册 + 引导去系统图库设置（文案统一由 SetWallpaperGuide 产出）
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
          const buf: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 95 });
          const dest: string = `${ctx.filesDir}/zeroone_export_${Date.now()}.jpg`;
          tempPath = dest;
          const f = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
          fileIo.writeSync(f.fd, buf);
          fileIo.closeSync(f);
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
      const err: BusinessError = e as BusinessError;
      promptAction.showToast({
        message: err && err.code !== undefined ? `保存失败（错误码 ${err.code}）` : '保存失败，请重试'
      });
    } finally {
      this.saving = false;
    }
  }

  // ==================== UI ====================

  /** 顶栏：标题 + 撤销/重做 */
  @Builder
  topBar() {
    Row() {
      Column({ space: 2 }) {
        Text('贴纸专区')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
        Text('背景 + 萌宠贴纸 · 贴出专属壁纸')
          .fontSize(11)
          .fontColor('#A8A8B5')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('↶')
        .fontSize(22)
        .fontColor(this.histIndex > 0 ? '#F2F2F5' : '#4A4A55')
        .width(38)
        .height(38)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.undo();
        })
      Text('↷')
        .fontSize(22)
        .fontColor(this.histIndex < this.histLen - 1 ? '#F2F2F5' : '#4A4A55')
        .width(38)
        .height(38)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.redo();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 10, top: 14, bottom: 4 })
  }

  /** 三步引导条：当前步高亮金色，已完成步置灰 */
  @Builder
  stepBar() {
    Row({ space: 6 }) {
      ForEach(this.stepLabels, (label: string, idx: number) => {
        Row({ space: 6 }) {
          Text(label)
            .fontSize(11)
            .fontWeight(idx + 1 === this.currentStep() ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(idx + 1 === this.currentStep() ? '#F0D08A'
              : (idx + 1 < this.currentStep() ? '#7E7E8A' : '#5A5A66'))
          if (idx < 2) {
            Text('›')
              .fontSize(11)
              .fontColor('#4A4A55')
          }
        }
      }, (label: string, idx: number) => idx.toString())
      Blank()
      Text(`${this.stickers.length} 张贴纸`)
        .fontSize(11)
        .fontColor('#A8A8B5')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  /** 背景层（id 归内容层，导出时一并截图） */
  @Builder
  bgLayer() {
    if (this.exportBgVisible && this.bgSrc !== undefined) {
      Image(this.bgSrc)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .brightness(1 + this.colorBrightness)
        .contrast(1 + this.colorContrast)
        .offset({ x: this.bgOffsetX, y: this.bgOffsetY })
        .transform(this.bgMatrix())
    }
  }

  /** 底部面板 chip */
  @Builder
  panelChip(tab: PanelTab) {
    Text(tab.label)
      .fontSize(12)
      .fontColor('#FFFFFF')
      .backgroundColor(this.panel === tab.key ? '#C9333D' : '#1C1D22')
      .padding({ left: 11, right: 11, top: 7, bottom: 7 })
      .borderRadius(14)
      .onClick(() => {
        if (this.collapsed) {
          this.collapsed = false;
        }
        this.panel = tab.key;
      })
  }

  /** 背景面板：相册 + 内置壁纸库 + 移除背景 */
  @Builder
  bgPanel() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text('📷 从相册选')
          .fontSize(13)
          .fontColor('#E8606A')
          .backgroundColor('#4A2E36')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(14)
          .onClick(() => {
            this.pickBgFromAlbum();
          })
        Text('🚫 不要背景')
          .fontSize(13)
          .fontColor('#C9C9D4')
          .backgroundColor('#2A2B32')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(14)
          .onClick(() => {
            this.clearBg();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      Grid() {
        LazyForEach(this.ds, (item: Wallpaper) => {
          GridItem() {
            Column() {
              Stack() {
                if (LocalWallpapers.getThumb(item.id) !== undefined) {
                  Image(LocalWallpapers.getThumb(item.id))
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                }
              }
              .width('100%')
              .aspectRatio(0.75)
              .clip(true)
              .borderRadius(10)
              .backgroundColor('#1C1D22')
              Text(item.category)
                .fontSize(10)
                .fontColor('#A8A8B5')
                .margin({ top: 4 })
            }
            .width('100%')
            .onClick(() => {
              this.pickLocalBg(item);
            })
          }
        }, (item: Wallpaper) => item.id)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(10)
      .padding({ left: 12, right: 12 })
      .height(196)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  /** 贴纸面板：分类 + 素材网格（可收藏）+ 删除/清空 */
  @Builder
  stickerPanel() {
    Column({ space: 6 }) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(STICKER_CATS, (c: StickerCat) => {
            Text(c.label)
              .fontSize(12)
              .fontColor(this.activeCat === c.key ? Color.White : '#C9C9D4')
              .backgroundColor(this.activeCat === c.key ? '#C9333D' : '#1C1D22')
              .padding({ left: 13, right: 13, top: 6, bottom: 6 })
              .borderRadius(13)
              .onClick(() => {
                this.activeCat = c.key;
                this.refreshPanelList();
              })
          }, (c: StickerCat) => c.key)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)

      Scroll() {
        Grid() {
          ForEach(this.panelList, (name: string) => {
            GridItem() {
              Stack() {
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
                Text(this.isFav(name) ? '★' : '☆')
                  .fontSize(14)
                  .fontColor(this.isFav(name) ? '#F0D08A' : '#6E6E7A')
                  .width(26)
                  .height(26)
                  .textAlign(TextAlign.Center)
                  .position({ x: '100%', y: 0 })
                  .markAnchor({ x: '100%', y: 0 })
                  .onClick(() => {
                    this.toggleFavP(name);
                  })
              }
              .width('100%')
              .aspectRatio(1)
            }
          }, (name: string) => name)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(6)
        .rowsGap(8)
        .padding({ left: 12, right: 12, top: 2, bottom: 6 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(186)
      .edgeEffect(EdgeEffect.Spring)

      Row({ space: 10 }) {
        Text('🗑 删除选中')
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor('#C9333D')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(14)
          .onClick(() => {
            this.removeSelected();
          })
        Text('🧹 清空')
          .fontSize(13)
          .fontColor('#C9C9D4')
          .backgroundColor('#2A2B32')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(14)
          .onClick(() => {
            this.clearAll();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  /** 图层面板：贴纸由上到下 + 背景层 */
  @Builder
  layerPanel() {
    Column({ space: 6 }) {
      if (this.stickers.length === 0 && this.bgKind === 0) {
        Text('画布还是空的：先去「背景」选一张，再到「贴纸」挑素材')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .padding({ top: 18, bottom: 18 })
      } else {
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.layersTop(), (s: StudioSticker, idx: number) => {
              Row({ space: 8 }) {
                Image($r(`app.media.${s.resName}`))
                  .width(30)
                  .height(30)
                  .objectFit(ImageFit.Contain)
                Text(`贴纸 ${idx + 1}`)
                  .fontSize(12)
                  .fontColor('#F2F2F5')
                  .layoutWeight(1)
                Text('🗑')
                  .fontSize(13)
                  .width(30)
                  .height(30)
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.removeSticker(s.id);
                  })
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.selectedId === s.id ? '#33343E' : '#1C1D22')
              .borderRadius(10)
              .onClick(() => {
                this.selectedId = s.id;
              })
            }, (s: StudioSticker) => s.id.toString())

            // 背景层永远在最下
            if (this.bgKind !== 0) {
              Row({ space: 8 }) {
                Text('🖼')
                  .fontSize(15)
                  .width(30)
                  .height(30)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#2A2B32')
                  .borderRadius(8)
                Text('背景')
                  .fontSize(12)
                  .fontColor('#C9C9D4')
                  .layoutWeight(1)
                Text('🗑')
                  .fontSize(13)
                  .width(30)
                  .height(30)
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.clearBg();
                  })
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#1C1D22')
              .borderRadius(10)
            }
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(200)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 10 })
  }

  /** 调整面板：阴影 + 调色 + 背景复位 */
  @Builder
  adjustPanel() {
    Column({ space: 2 }) {
      Row({ space: 10 }) {
        Text('阴影')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Toggle({ type: ToggleType.Switch, isOn: this.shadowEnabled })
          .selectedColor('#C9333D')
          .onChange((on: boolean) => {
            this.shadowEnabled = on;
            this.commit();
          })
        Blank()
        Text('↺ 背景复位')
          .fontSize(12)
          .fontColor('#E8606A')
          .backgroundColor('#4A2E36')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .onClick(() => {
            this.resetBgTransform();
            this.commit();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2 })

      Row({ space: 10 }) {
        Text('透明度')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.shadowOpacity, min: 0, max: 0.8, step: 0.05 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.shadowOpacity = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.shadowOpacity * 100)}%`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('模糊度')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.shadowBlur, min: 0, max: 20, step: 1 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.shadowBlur = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.shadowBlur)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('X 偏移')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.shadowOffsetX, min: -20, max: 20, step: 1 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.shadowOffsetX = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.shadowOffsetX)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('Y 偏移')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.shadowOffsetY, min: -20, max: 20, step: 1 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.shadowOffsetY = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.shadowOffsetY)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('亮度')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.colorBrightness, min: -0.5, max: 0.5, step: 0.05 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.colorBrightness = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.colorBrightness * 100)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('对比度')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.colorContrast, min: -0.5, max: 0.5, step: 0.05 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.colorContrast = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.colorContrast * 100)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('色温')
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(48)
        Slider({ value: this.colorWarmth, min: -0.5, max: 0.5, step: 0.05 })
          .layoutWeight(1)
          .selectedColor('#C9333D')
          .onChange((v: number, mode: SliderChangeMode) => {
            this.colorWarmth = v;
            if (mode === SliderChangeMode.End) {
              this.commit();
            }
          })
        Text(`${Math.round(this.colorWarmth * 100)}`)
          .fontSize(12)
          .fontColor('#A8A8B5')
          .width(38)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 10 }) {
        Text('↺ 重置调色')
          .fontSize(13)
          .fontColor('#E8606A')
          .backgroundColor('#4A2E36')
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(14)
          .onClick(() => {
            this.colorBrightness = 0;
            this.colorContrast = 0;
            this.colorWarmth = 0;
            this.commit();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4 })
    }
    .width('100%')
    .padding({ top: 4, bottom: 10 })
  }

  /** 导出面板：格式 + 比例 + SaveButton */
  @Builder
  exportPanel() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        ForEach(EXPORT_TARGETS, (it: ExportTargetItem) => {
          Text(it.label)
            .fontSize(11)
            .fontColor(this.exportTarget === it.t ? Color.White : '#A8A8B5')
            .backgroundColor(this.exportTarget === it.t ? '#C9333D' : '#2A2B32')
            .layoutWeight(1)
            .height(28)
            .textAlign(TextAlign.Center)
            .borderRadius(14)
            .onClick(() => {
              this.exportTarget = it.t;
            })
        }, (it: ExportTargetItem) => `${it.t}`)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('比例')
          .fontSize(11)
          .fontColor('#A8A8B5')
        ForEach(EXPORT_RATIOS, (r: string) => {
          Text(r === 'free' ? '自由' : r)
            .fontSize(11)
            .fontColor(this.exportRatio === r ? Color.White : '#A8A8B5')
            .backgroundColor(this.exportRatio === r ? '#C9333D' : '#1C1D22')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .borderRadius(10)
            .onClick(() => {
              this.exportRatio = r;
              this.updateBoxSize();
            })
        }, (r: string) => r)
        Blank()
        Text('做壁纸选 9:16')
          .fontSize(9)
          .fontColor('#A8A8B5')
      }
      .width('100%')

      SaveButton({
        icon: SaveIconStyle.FULL_FILLED,
        buttonType: ButtonType.Capsule
      })
        .width('100%')
        .height(38)
        .enabled(!this.saving)
        .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS) {
            this.save(this.exportTarget);
          }
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 10 })
  }

  build() {
    Column() {
      this.topBar()
      this.stepBar()

      // ===== 画布区 + 面板 =====
      Column() {
        // 导出中提示：截图 + 编码需要时间，给出明确反馈
        if (this.saving) {
          Row({ space: 6 }) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color('#C9333D')
            Text('正在导出，请稍候…')
              .fontSize(11)
              .fontColor('#A8A8B5')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 4 })
        }

        // 预览区（外层 = 可用区域；白框 = 导出范围）
        Stack() {
          // ===== 内容层（id = stickerCanvas，保存时直接截图）=====
          // 注意：这一层不设 backgroundColor —— 导出透明 PNG 时 alpha 才不会被底色破坏
          Stack() {
            this.bgLayer()

            ForEach(this.stickers, (s: StudioSticker) => {
              StickerNode({
                item: s,
                selected: s.id === this.selectedId,
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
                  this.selectedId = s.id;
                },
                onDirty: () => {
                  this.transformTick = this.transformTick + 1;
                },
                onCommit: () => {
                  this.commit();
                },
                onDelete: () => {
                  this.removeSticker(s.id);
                }
              })
            }, (s: StudioSticker) => s.id.toString())

            // 色温叠加层（暖 = 橙 / 冷 = 蓝；导出透明 PNG 时一并隐藏）
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
          .id('stickerCanvas')
          .width(this.compW)
          .height(this.compH)
          .clip(true)

          // ===== 框饰层（不进截图）：白框 + 提示 + 空态 =====
          Stack() {
            Column()
              .width('100%')
              .height('100%')
              .border({ width: 2, color: Color.White })
              .borderRadius(4)
              .hitTestBehavior(HitTestMode.None)

            if (this.stickers.length === 0) {
              Column({ space: 6 }) {
                Text(this.bgKind === 0 ? '① 先选一张背景图' : '② 挑一张贴纸贴上')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#F2F2F5')
                Text(this.bgKind === 0
                  ? '点下方「背景」挑图，也可直接导出透明 PNG'
                  : '拖动 · 双指缩放旋转')
                  .fontSize(11)
                  .fontColor('#C9C9D4')
                  .textAlign(TextAlign.Center)
                  .lineHeight(17)
              }
              .width('86%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(12)
              .backgroundColor('rgba(0,0,0,0.5)')
              .hitTestBehavior(HitTestMode.None)
            }

            // 选中贴纸的缩放滑杆（浮在贴纸下方，不进截图）
            if (this.selectedId >= 0 && this.selectedSticker() !== undefined) {
              Row({ space: 8 }) {
                Text('－')
                  .fontSize(14)
                  .fontColor('#B0B0B0')
                Slider({
                  value: this.selScale(),
                  min: 0.3,
                  max: 4,
                  step: 0.05,
                  style: SliderStyle.OutSet
                })
                  .layoutWeight(1)
                  .blockColor('#C9333D')
                  .selectedColor('#C9333D')
                  .trackColor('rgba(255,255,255,0.35)')
                  .onChange((v: number, mode: SliderChangeMode) => {
                    const it: StudioSticker | undefined = this.selectedSticker();
                    if (it !== undefined) {
                      it.scale = v;
                      this.transformTick = this.transformTick + 1;
                    }
                    if (mode === SliderChangeMode.End) {
                      this.commit();
                    }
                  })
                Text('＋')
                  .fontSize(18)
                  .fontColor('#C9333D')
                  .fontWeight(FontWeight.Bold)
              }
              .width(200)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(16)
              .backgroundColor('rgba(0,0,0,0.6)')
              .position({ x: (this.compW - 200) / 2, y: this.stickerSliderY() })
              .hitTestBehavior(HitTestMode.Default)
            }
          }
          .width(this.compW)
          .height(this.compH)
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#101014')
        // 背景取景手势（触摸空白处生效；在贴纸上时贴纸手势优先）
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture()
              .onActionStart(() => {
                this.onBgPanStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onBgPanUpdate(e);
              })
              .onActionEnd(() => {
                this.commit();
              }),
            PinchGesture()
              .onActionStart(() => {
                this.onBgPinchStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onBgPinchUpdate(e);
              })
              .onActionEnd(() => {
                this.commit();
              })
          )
        )
        .onClick(() => {
          this.selectedId = -1; // 点空白取消选中
        })
        .onAreaChange((_: Area, newValue: Area) => {
          this.availW = newValue.width as number;
          this.availH = newValue.height as number;
          this.updateBoxSize();
        })

        // ===== 面板头：chips + 收起/展开 =====
        Row({ space: 8 }) {
          ForEach(PANEL_TABS, (tab: PanelTab) => {
            this.panelChip(tab)
          }, (tab: PanelTab) => tab.key)
          Blank()
          Text(this.collapsed ? '🔼' : '🔽')
            .fontSize(13)
            .fontColor('#A8A8B5')
            .backgroundColor('#1C1D22')
            .width(34)
            .height(30)
            .textAlign(TextAlign.Center)
            .borderRadius(14)
            .onClick(() => {
              this.collapsed = !this.collapsed;
            })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })

        // ===== 面板内容（收起时整块隐藏，画布最大化） =====
        if (!this.collapsed) {
          if (this.panel === 'background') {
            this.bgPanel()
          } else if (this.panel === 'sticker') {
            this.stickerPanel()
          } else if (this.panel === 'layer') {
            this.layerPanel()
          } else if (this.panel === 'adjust') {
            this.adjustPanel()
          } else {
            this.exportPanel()
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F0F12')
  }
}