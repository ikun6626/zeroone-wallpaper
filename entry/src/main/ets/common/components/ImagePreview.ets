import { Wallpaper } from '../../model/Wallpaper';
import { promptAction, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { ImageEditor } from './ImageEditor';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { WallpaperApi } from '../net/WallpaperApi';
import { ImageCache } from '../net/ImageCache';
import { Haptics } from '../utils/Haptics';
import { RemoteImage } from './RemoteImage';
import { LocalWallpapers } from '../constants/LocalWallpapers';
import { SetWallpaperGuidePanel, WallpaperKind } from './SetWallpaperGuide';
import { EditGuard } from '../utils/EditGuard';
import { CanvasSpec } from '../canvas/CanvasSpec';
import { CanvasPresets, CanvasPreset, PresetIds } from '../canvas/CanvasPresets';
import { Size } from '../canvas/ViewTransform';
import { ViewTransform, ViewMath } from '../canvas/ViewTransform';
import { composeCoverToJpeg } from '../editor/ImageComposer';

/** 最大缩放倍数 */
const MAX_SCALE: number = 4;
/** 双击放大后的倍数 */
const DOUBLE_SCALE: number = 2.5;
/** 下滑多少距离触发关闭 */
const DISMISS_THRESHOLD: number = 120;
/** 左右滑多少距离（vp）触发切换上/下一张 */
const SWITCH_THRESHOLD: number = 70;
/** 切图过渡时长（ms）：旧图退出 / 新图进入各一段 */
const SWITCH_ANIM_MS: number = 140;
/**
 * 铺满(cover)允许裁掉的最大图片比例：超过则默认改用「适应」完整显示。
 * 0.15 表示最多裁掉整张图的 15%（约每边 7.5%）仍算「铺满可接受」。
 * 想要更激进的完整显示就调小，想更贴近壁纸效果就调大。
 */
const COVER_CROP_TOLERANCE: number = 0.15;

/**
 * 按文件头魔数判断图片真实格式，返回相册资产所需的扩展名。
 *
 * 为什么不用原文件名后缀：预览页的临时文件统一叫 `.jpg`（云端下载 / 本地随包都写这个路径），
 * 但云端原图可能被转码成 webp / png —— 直接按 `.jpg` 建资产会让相册解不出图。
 * 只服务"适应 = 存原图"的透传路径；铺满路径恒为 JPEG 编码结果，不需要本函数。
 */
function detectImageExt(path: string): string {
  let ext: string = 'jpg';
  const buf: ArrayBuffer = new ArrayBuffer(12);
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const read: number = fileIo.readSync(file.fd, buf);
      if (read >= 12) {
        const b: Uint8Array = new Uint8Array(buf);
        if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {
          ext = 'png';
        } else if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46
          && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) {
          ext = 'webp';
        } else if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) {
          ext = 'gif';
        } else if (b[0] === 0x42 && b[1] === 0x4D) {
          ext = 'bmp';
        }
        // JPEG(FF D8) 等其余情况沿用默认 'jpg'
      }
    } finally {
      fileIo.closeSync(file);
    }
  } catch (e) {
    // 读文件头失败：保守沿用 'jpg'
  }
  return ext;
}

/**
 * ImagePreview —— 全屏大图预览（Cuto 风格）
 *
 * 特性：
 *  - 纯黑背景 + 图片**铺满屏幕**（cover，与 Cuto 一致）：所见即壁纸实际效果
 *  - 左上圆形返回箭头；底部 Cuto 式磨砂胶囊：收藏 / 预览模式 / 保存并设为壁纸 / 编辑
 *  - 保存成功后弹出图库设置引导（三方应用无法直接换壁纸，见 SetWallpaperGuide）
 *  - 单击图片：工具栏/返回箭头在显示 ↔ 隐藏之间切换（沉浸式看图）
 *  - 双指捏合缩放；双击放大/还原；放大后单指拖动浏览
 *  - 未放大时**左右滑切换上一张 / 下一张**（与首页 Hero 轮播一致）；下滑带动画关闭
 *  - 保存结果**跟随当前显示方式**（所见即所得）：
 *      铺满 → 按设备屏幕像素离屏合成（cover + 当前缩放/平移 = 用户所见），
 *             存出来就是手机比例，设为锁屏/桌面不会被系统二次裁切；
 *      适应 → **直接存原图**（不裁切、不缩放、不重编码），保留原始构图与比例
 *  - 预览模式：普通 → iOS 桌面 → iOS 锁屏（模拟壁纸实际效果）
 */
@Component
export struct ImagePreview {
  /** 初始展示的壁纸（左右滑切换后由内部状态 cur 接管） */
  @Prop @Watch('onWallpaperPropChange') wallpaper: Wallpaper = new Wallpaper();
  /**
   * 取相邻壁纸：current = 当前展示项，dir = -1 上一张 / +1 下一张；
   * 返回 undefined 表示已到列表尽头。
   * 由调用页提供 —— 各页的列表不同（首页 Hero+分区、合辑详情、我的收藏）。
   */
  neighbor: (current: Wallpaper, dir: number) => Wallpaper | undefined =
    (_current: Wallpaper, _dir: number): Wallpaper | undefined => undefined;
  onClose: () => void = () => {};

  /** 当前正在展示的壁纸（初始 = wallpaper 入参） */
  @State cur: Wallpaper = new Wallpaper();
  /** 左右滑切图的水平位移（vp）：拖动跟手 + 切图进出动画 */
  @State switchDx: number = 0;
  /** 本次拖动主轴是否为水平（决定松手后是切图还是关闭/复位） */
  private lastAxisHorizontal: boolean = false;

  /** 缩放 / 平移 / 关闭动画 */
  @State zoomScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State dismissX: number = 0;
  @State dismissY: number = 0;
  @State dismissOpacity: number = 1;
  @State saving: boolean = false;
  @State showEditor: boolean = false;
  /** 预览区尺寸（vp）：由 onAreaChange 记录，用于夹紧平移与归一化换算 */
  @State frameW: number = 0;
  @State frameH: number = 0;
  /** 工具栏/返回箭头是否可见（单击图片切换） */
  @State uiVisible: boolean = true;
  /** 预览模式：normal / home / lock */
  @State previewMode: string = 'normal';
  /**
   * 图片显示方式：true = Cover 铺满（= 设为壁纸后的真实效果）
   *                false = Contain 适应（完整显示整张图，上下留黑边）
   *
   * 默认策略（自适应屏幕比例）：铺满必然裁掉一部分图，裁多少取决于
   * 「图片比例 vs 当前机型屏幕比例」的差距 —— 差距小（如 9:16 图放到细长屏）
   * 就铺满，差距大（如 2:3 / 4:3 图放到 9:20 屏会被裁掉 20%+）就改「适应」完整显示。
   * 同一张图在 16:9 / 19.5:9 / 折叠屏上会得到不同结论。见 decideFitCover()。
   */
  @State fitCover: boolean = true;
  /** 用户是否手动点过「铺满/适应」：点过之后 onInfo 不再自动覆盖其选择 */
  private userTouchedFit: boolean = false;
  /** 收藏状态（简易本地存储） */
  @State isFav: boolean = false;
  /** 时钟刷新计数：每分钟 +1，驱动锁屏/桌面模拟层时间重绘 */
  @State nowTick: number = 0;
  /** 时钟定时器句柄（-1 表示未启动） */
  private clockTimer: number = -1;
  /**
   * 设为壁纸引导卡片的目标：-1 表示不显示
   * 只在“保存成功”之后才置为非负值，保证引导不会先于结果出现
   */
  @State guideKind: number = -1;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;

  aboutToAppear(): void {
    // 内部展示项以入参初始化（之后左右滑切换只改 cur，不动父页面的 previewItem）
    this.cur = this.wallpaper;
    // P1：每次重新进入预览都回到「普通」模式，避免上次的锁屏/桌面模拟残留
    this.previewMode = 'normal';
    // 进入预览时读取本地收藏状态，保证与首页/合辑/我的页面一致
    this.isFav = PreferenceUtil.isFavorite(this.cur.id);
    this.startClockTicker();
    // 注册返回键处理：预览是覆盖层，返回键应关闭预览。
    // 此前没有这个拦截，用户按返回键会直接把 App 退出（真实且高频的体验事故）。
    this.backId = EditGuard.push((): boolean => {
      this.dismiss();
      return true;
    });
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
    // 离开预览时停掉时钟定时器，避免泄漏
    // 注意：句柄可能是 setTimeout(对齐整分钟) 或 setInterval(之后的每分钟)，
    // 两者共用同一 id 空间，clearInterval 对已触发的 timeout 是安全空操作。
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  /** 启动时钟：先对齐到下一个整分钟，之后每 60s 刷新一次 nowTick */
  private startClockTicker(): void {
    const update: () => void = (): void => {
      this.nowTick++;
    };
    const now: Date = new Date();
    const msToNextMinute: number = 60000 - (now.getSeconds() * 1000 + now.getMilliseconds());
    this.clockTimer = setTimeout(() => {
      update();
      this.clockTimer = setInterval(update, 60000);
    }, msToNextMinute);
  }

  private clampZoom(value: number): number {
    return Math.min(MAX_SCALE, Math.max(1, value));
  }

  /**
   * 当前预览区（≈屏幕可视区）的宽高比。优先用 onAreaChange 记录的实际尺寸；
   * 若图片解码早于首次布局返回，则退回系统显示的屏幕比例兜底。
   */
  private containerRatio(): number {
    if (this.frameW > 0 && this.frameH > 0) {
      return this.frameW / this.frameH;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d.height > 0) {
        return d.width / d.height;
      }
    } catch (e) {
      return 0;
    }
    return 0;
  }

  /**
   * 按「图片比例 vs 当前屏幕比例」自适应决定 铺满(cover) / 适应(contain)。
   *
   * 铺满必然裁掉一部分图，裁切比例 = 1 - min(屏比, 图比) / max(屏比, 图比)：
   *   - 图片比例越接近屏幕 → 裁得越少 → 铺满越自然（如 9:16 图放 16:9 屏）；
   *   - 差距越大 → 裁得越多 → 改「适应」完整显示（如 2:3 图放 9:20 细长屏）。
   * 阈值 COVER_CROP_TOLERANCE 控制「最多容忍裁掉多少」。
   */
  private decideFitCover(w: number, h: number): boolean {
    if (w <= 0 || h <= 0) {
      return this.fitCover;
    }
    const scr: number = this.containerRatio();
    if (scr <= 0) {
      return this.fitCover;
    }
    const img: number = w / h;
    const crop: number = 1 - Math.min(scr, img) / Math.max(scr, img);
    return crop <= COVER_CROP_TOLERANCE;
  }

  /** 父页面换了一张壁纸（如从收藏列表再点一张）→ 内部展示项同步 */
  onWallpaperPropChange(): void {
    if (this.wallpaper.id === this.cur.id) {
      return;
    }
    this.cur = this.wallpaper;
    this.isFav = PreferenceUtil.isFavorite(this.cur.id);
    this.resetView();
  }

  /** 远程图地址：优先原图，没有原图用缩略图（本地壁纸返回空串） */
  private remoteSrc(): string {
    if (this.cur.imageUrl.length > 0) {
      return this.cur.imageUrl;
    }
    return this.cur.thumbUrl;
  }

  /** 当前图的随包兜底资源（原图尺寸，预览/编辑/保存都用它） */
  private curLocalImg(): Resource | undefined {
    return LocalWallpapers.getLocalImg(this.cur.id);
  }

  /** 复位缩放/平移/滑动位移（切图后必须复位，否则沿用上一张的偏移会"跳一下"） */
  private resetView(): void {
    this.zoomScale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.switchDx = 0;
    this.dismissX = 0;
    this.dismissY = 0;
    this.dismissOpacity = 1;
    this.baseScale = 1;
    this.baseOffsetX = 0;
    this.baseOffsetY = 0;
  }

  /**
   * 切到相邻一张：旧图沿滑动方向滑出 → 换图 → 新图从反方向滑入。
   * 到头时弹提示并把位移复位。
   * @param dir -1 上一张（右滑）/ +1 下一张（左滑）
   */
  private goNeighbor(dir: number): void {
    const next: Wallpaper | undefined = this.neighbor(this.cur, dir);
    const w: number = this.frameW > 0 ? this.frameW : 360;
    if (next === undefined) {
      promptAction.showToast({ message: dir > 0 ? '已经是最后一张' : '已经是第一张' });
      animateTo({ duration: SWITCH_ANIM_MS, curve: Curve.EaseOut }, () => {
        this.switchDx = 0;
      });
      return;
    }
    Haptics.light();
    // 旧图滑出
    animateTo({ duration: SWITCH_ANIM_MS, curve: Curve.EaseIn }, () => {
      this.switchDx = dir > 0 ? -w : w;
      this.dismissOpacity = 0;
    });
    setTimeout(() => {
      this.cur = next;
      this.isFav = PreferenceUtil.isFavorite(next.id);
      this.resetView();
      // 新图先摆到另一侧再滑入
      this.switchDx = dir > 0 ? w : -w;
      this.dismissOpacity = 0;
      animateTo({ duration: SWITCH_ANIM_MS, curve: Curve.EaseOut }, () => {
        this.switchDx = 0;
        this.dismissOpacity = 1;
      });
    }, SWITCH_ANIM_MS);
  }

  /**
   * 下载远程图到沙箱临时文件（云端壁纸的保存链路）。
   * 走 ImageCache：浏览/预览过的图直接命中磁盘缓存，零流量秒存。
   * 下载/写盘失败抛错（由调用方统一提示）。
   */
  private async downloadRemote(dest: string): Promise<void> {
    const buf: ArrayBuffer = await ImageCache.fetchBytes(this.remoteSrc());
    if (buf.byteLength <= 0) {
      throw new Error('empty body');
    }
    const file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, buf);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 把当前缩放/平移夹回合法范围（放大后拖动、缩小时都要过这一道，避免露出黑边） */
  private clampPan(): void {
    const mx: number = ViewMath.maxPan(this.zoomScale, this.frameW);
    const my: number = ViewMath.maxPan(this.zoomScale, this.frameH);
    this.offsetX = ViewMath.clampValue(this.offsetX, -mx, mx);
    this.offsetY = ViewMath.clampValue(this.offsetY, -my, my);
  }

  /** 预览的缩放/平移 → 与设备无关的归一化变换（导出侧复用同一套几何） */
  private currentViewTransform(): ViewTransform {
    const w: number = this.frameW > 0 ? this.frameW : 1;
    const h: number = this.frameH > 0 ? this.frameH : 1;
    return new ViewTransform(this.zoomScale, this.offsetX / w, this.offsetY / h);
  }

  /**
   * 按画布（= 手机屏幕像素）合成 JPEG —— **仅用于「铺满」模式**的保存
   * （「适应」模式不走这里，直接拷原图，见 saveToAlbum）
   * @param srcPath 沙箱内的原图文件路径
   */
  private async composeCanvasRatio(srcPath: string): Promise<ArrayBuffer> {
    const device: CanvasSpec = CanvasSpec.fromDevice();
    // 走预设模型（"手机屏幕"预设 = 设备尺寸，行为与之前完全一致）：
    // 阶段 5 的"比例/模板"栏会复用同一条路径，这里先把它接进真实导出链路。
    const preset: CanvasPreset = CanvasPresets.byId(PresetIds.DEVICE);
    const size: Size = CanvasPresets.sizeFor(preset, { width: device.width, height: device.height });
    const source: image.ImageSource = image.createImageSource(srcPath);
    let pm: image.PixelMap | undefined = undefined;
    try {
      pm = await source.createPixelMap();
      const info: image.ImageInfo = pm.getImageInfoSync();
      return await composeCoverToJpeg(pm, info.size.width, info.size.height,
        size.width, size.height, this.currentViewTransform(), 95);
    } finally {
      if (pm !== undefined) {
        pm.release();
      }
      source.release();
    }
  }

  /** 当前时间 h:mm（12 小时制，锁屏/桌面大号用） */
  private currentTimeShort(): string {
    // 读取 nowTick 建立渲染依赖：分钟变化时定时器驱动重绘
    if (this.nowTick < 0) { return ''; }
    const d = new Date();
    const h24: number = d.getHours();
    const h: number = h24 % 12 === 0 ? 12 : h24 % 12;
    const m = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }

  /** 上午 / 下午（动态计算，不再写死「下午」） */
  private currentPeriod(): string {
    if (this.nowTick < 0) { return ''; }
    return new Date().getHours() < 12 ? '上午' : '下午';
  }

  /** 当前日期：周M月D日 */
  private currentDateStr(): string {
    // 跨零点时随 nowTick 一起刷新
    if (this.nowTick < 0) { return ''; }
    const d = new Date();
    const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    return `${weekdays[d.getDay()]} ${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /** HarmonyOS 系统图标项：SymbolGlyph（系统符号）+ 彩色圆角方块 + 标签 */
  @Builder
  iconItem(symbol: Resource, bgColor: string, label: string, fgColor: string = '#FFFFFF') {
    Column({ space: 4 }) {
      Column() {
        SymbolGlyph(symbol)
          // SymbolGlyph.fontColor 接受 ResourceColor[]（多色），不是单个颜色
          .fontColor([fgColor])
          .fontSize(26)
      }
      .width(54)
      .height(54)
      .backgroundColor(bgColor)
      .borderRadius(16)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      if (label.length > 0) {
        Text(label)
          .fontSize(11)
          .fontColor(Color.White)
          .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 工具栏上的"保存 / 设为壁纸"按钮（与收藏、预览模式、编辑同排）
   *
   * 说明：写系统相册必须有 SaveButton 的临时授权，普通 Text/Button 点击没有授权，
   * createAsset 会直接抛权限错误，所以这里必须是安全控件（不能自己画一个图标）；
   * 但外观是能改的 —— `SecurityComponentMethod`（SaveButtonAttribute 的基类）提供了
   * `backgroundColor / iconColor / iconSize / fontColor`，所以可以把它做成
   * "无底色 + 白色图标"，和旁边三个 emoji 图标视觉统一。
   */
  @Builder
  saveWallpaperButton() {
    SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Circle })
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .iconColor('#F2F2F5')
      .iconSize(22)
      .onClick((_: ClickEvent, result: SaveButtonOnClickResult) => {
        if (result === SaveButtonOnClickResult.SUCCESS && !this.saving) {
          // 保存结果跟随当前显示方式（所见即所得）：铺满 → 按屏幕合成壁纸成品；适应 → 存原图。
          // 锁屏/桌面在保存后的步骤卡片里选（仅铺满模式弹该卡片，见 saveToAlbum）。
          this.saveToAlbum(WallpaperKind.LOCK);
        }
      })
  }

  private onDoubleTap(): void {
    animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
      if (this.zoomScale > 1) {
        this.zoomScale = 1;
        this.offsetX = 0;
        this.offsetY = 0;
      } else {
        this.zoomScale = DOUBLE_SCALE;
      }
    });
  }

  /** 关闭预览：图片向下飞出 + 淡出 */
  private dismiss(): void {
    animateTo({ duration: 180, curve: Curve.EaseIn }, () => {
      this.dismissX = 0;
      this.dismissY = 600;
      this.dismissOpacity = 0;
    });
    setTimeout(() => { this.onClose(); }, 180);
  }

  /**
   * 保存到系统相册 —— 保存结果**跟随当前显示方式**（所见即所得）：
   *   铺满 → 按设备屏幕像素合成 cover 成品（= 设为壁纸的真实效果），并展示设置引导卡片；
   *   适应 → **直接存原图**（不裁切 / 不缩放 / 不重编码），不弹壁纸引导
   *          （原图不是"可直接设为壁纸的成品"，系统仍会自行裁切，弹引导语义不通）
   * @param guideKind 引导卡片默认展开的目标：WallpaperKind.LOCK / HOME（仅铺满模式使用）
   */
  async saveToAlbum(guideKind: number): Promise<void> {
    if (this.saving) return;
    // 保存无需登录（用户体系暂未开放）：本地壁纸直接读随包资源，云端壁纸先下载
    const localRes: Resource | undefined = this.curLocalImg();
    if (localRes === undefined && this.remoteSrc().length === 0) {
      promptAction.showToast({ message: '图片资源缺失' });
      return;
    }
    const keepOriginal: boolean = !this.fitCover;
    this.saving = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const dest: string = `${ctx.filesDir}/zeroone_preview_${Date.now()}.jpg`;
    let tempCreated: boolean = false;
    let isCloud: boolean = false;
    try {
      if (this.cur.isCloud) {
        // 云端壁纸（即使有随包兜底图）：下载云端高清原图
        await this.downloadRemote(dest);
        tempCreated = true;
        isCloud = true;
      } else if (localRes !== undefined) {
        // 纯本地壁纸：源图来自随包内置资源
        const content: Uint8Array = await ctx.resourceManager.getMediaContent(localRes);
        const srcFile = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fileIo.writeSync(srcFile.fd, content.buffer as ArrayBuffer);
        fileIo.closeSync(srcFile);
        tempCreated = true;
      }

      if (!keepOriginal) {
        // 铺满：按设备屏幕像素离屏合成（cover + 当前缩放/平移 = 用户所见），
        // 存出来的图就是手机比例，设为壁纸/桌面不会被系统二次裁切。
        const bytes: ArrayBuffer = await this.composeCanvasRatio(dest);
        const out = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(out.fd, bytes);
        fileIo.closeSync(out);
      }
      // 适应：不做任何合成 —— dest 中的源图字节原样写入相册（无损，且更快更省内存）。
      // 用户若在适应模式下双指放大过，仅属浏览行为，不改变成图（按产品要求"适应=原图"）。

      const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      // 原图透传时真实格式可能是 png / webp（云端转码），按魔数取后缀，
      // 否则写进 .jpg 资产会让相册解不出图；铺满模式恒为 JPEG 编码结果。
      const assetExt: string = keepOriginal ? detectImageExt(dest) : 'jpg';
      const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, assetExt);
      const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
      fileIo.copyFileSync(dest, file.fd);
      fileIo.closeSync(file);
      // 云端壁纸：上报一次下载（管理后台统计），失败不影响保存结果
      if (isCloud) {
        WallpaperApi.reportDownload(this.cur.cloudId);
      }
      // 保存成功触感
      Haptics.success();
      if (keepOriginal) {
        promptAction.showToast({ message: '已保存 · 原图' });
      } else {
        promptAction.showToast({ message: '已保存 · 铺满' });
        // 保存成功后展示引导卡片（在 SaveButton 回调之外渲染）：
        // 卡片里可以切"锁屏 / 桌面"，所以主 CTA 只需要一个（Cuto 同款流程）。
        this.guideKind = guideKind;
      }
    } catch (e) {
      console.error(`saveToAlbum failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '保存失败，请重试' });
    } finally {
      // 拷贝进相册后删除沙箱临时文件
      if (tempCreated) {
        try {
          fileIo.unlinkSync(dest);
        } catch (e) {
          // 忽略：文件可能已被编辑器清理
        }
      }
      this.saving = false;
    }
  }

  build() {
    Stack() {
      // ===== 1. 黑色底 =====
      Column()
        .width('100%').height('100%')
        .backgroundColor(Color.Black)

      // ===== 2. 图片（Cover 铺满屏幕 = 壁纸实际效果；放大后可拖动查看局部） =====
      // 此前用 Contain 完整显示，横图和方图会在上下留大片黑边、比例"很怪"，
      // 而且与"设为壁纸"后的效果完全不一致 —— 现在预览即壁纸效果。
      Stack() {
        // 云端壁纸：远程原图（走三级缓存）；本地壁纸：随包内置资源。
        RemoteImage({
          url: this.remoteSrc(),
          fallback: this.curLocalImg(),
          fit: this.fitCover ? ImageFit.Cover : ImageFit.Contain,
          fallbackFit: this.fitCover ? ImageFit.Cover : ImageFit.Contain,
          onInfo: (w: number, h: number): void => {
            // 按「图片比例 vs 当前屏幕比例」自适应决定铺满/适应（见 decideFitCover）；
            // 用户已手动点过切换按钮，则不再自动覆盖其选择。
            if (!this.userTouchedFit) {
              this.fitCover = this.decideFitCover(w, h);
            }
          }
        })
          .geometryTransition(`wpic_${this.cur.id}`)
      }
      .width('100%')
      .height('100%')
      .scale({ x: this.zoomScale, y: this.zoomScale })
      .translate({ x: this.offsetX + this.dismissX + this.switchDx, y: this.offsetY + this.dismissY })
      .opacity(this.dismissOpacity)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        // 记录预览区尺寸（vp）：平移夹紧与导出归一化都依赖它
        this.frameW = Number(newValue.width);
        this.frameH = Number(newValue.height);
      })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          // 双指捏合缩放
          PinchGesture({ fingers: 2 })
            .onActionStart(() => { this.baseScale = this.zoomScale; })
            .onActionUpdate((e: GestureEvent) => {
              this.zoomScale = this.clampZoom(this.baseScale * e.scale);
              // 缩回去时把平移夹回合法范围，避免露出黑边
              this.clampPan();
            }),
          // 双击 → 放大/还原；单击 → 切换工具栏显隐
          TapGesture({ count: 2 })
            .onAction(() => { this.onDoubleTap(); }),
          TapGesture({ count: 1 })
            .onAction(() => {
              if (this.zoomScale <= 1) {
                // 单击图片 → 切换工具栏显隐（沉浸式）
                animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
                  this.uiVisible = !this.uiVisible;
                });
              }
            }),
          // 拖动：放大后平移 / 未放大时左右滑切图、下滑关闭
          PanGesture()
            .onActionStart(() => {
              this.baseOffsetX = this.offsetX;
              this.baseOffsetY = this.offsetY;
            })
            .onActionUpdate((e: GestureEvent) => {
              if (this.zoomScale > 1) {
                // 放大后拖动：夹在可视余量内，图片永远盖满屏幕
                const mx: number = ViewMath.maxPan(this.zoomScale, this.frameW);
                const my: number = ViewMath.maxPan(this.zoomScale, this.frameH);
                this.offsetX = ViewMath.clampValue(this.baseOffsetX + e.offsetX, -mx, mx);
                this.offsetY = ViewMath.clampValue(this.baseOffsetY + e.offsetY, -my, my);
                return;
              }
              // 未放大：按主轴分流 —— 水平 = 切上/下一张，垂直 = 下滑关闭（上滑不响应）
              this.lastAxisHorizontal = Math.abs(e.offsetX) > Math.abs(e.offsetY);
              if (this.lastAxisHorizontal) {
                // 图片跟手左右移动；另一轴清零，避免方向切换时残留位移
                this.dismissX = 0;
                this.dismissY = 0;
                this.dismissOpacity = 1;
                this.switchDx = e.offsetX;
              } else {
                this.switchDx = 0;
                this.dismissX = 0;
                this.dismissY = Math.max(0, e.offsetY);
                this.dismissOpacity = Math.max(0, 1 - this.dismissY / 400);
              }
            })
            .onActionEnd(() => {
              if (this.zoomScale > 1) {
                return;
              }
              if (this.lastAxisHorizontal) {
                if (this.switchDx <= -SWITCH_THRESHOLD) {
                  // 左滑 → 下一张
                  this.goNeighbor(1);
                } else if (this.switchDx >= SWITCH_THRESHOLD) {
                  // 右滑 → 上一张
                  this.goNeighbor(-1);
                } else {
                  animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
                    this.switchDx = 0;
                  });
                }
                return;
              }
              if (this.dismissY > DISMISS_THRESHOLD) {
                // 下滑触发 → 向下飞出关闭
                this.dismiss();
              } else {
                animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
                  this.dismissY = 0;
                  this.dismissOpacity = 1;
                });
              }
            })
        )
      )

      // ===== 3. 桌面预览模拟层（EMUI / HarmonyOS 经典桌面风格） =====
      if (this.previewMode === 'home') {
        Column() {
          // 这里不再画"假状态栏"（信号/网速/电量）：真机顶部本来就有系统状态栏，
          // 叠一份只会显得脏 —— 参考 Cuto，模拟层只留时钟/日期/图标这些壁纸内容本身。
          // 大号时间 + 右侧温度 + 日期
          Row() {
            Text(this.currentTimeShort())
              .fontSize(64).fontWeight(FontWeight.Lighter)
              .fontColor(Color.White)
              .fontFamily('HarmonyOS Sans')
              .textShadow({ radius: 6, color: '#88000000', offsetX: 0, offsetY: 1 })
            Text(this.currentPeriod())
              .fontSize(18).fontColor(Color.White)
              .margin({ left: 4, top: 20 })
          }
          .width('100%')
          // 浅色壁纸上白字会看不清：给时钟区加一层半透明暗色底
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .backgroundColor('#33000000')

          Text(this.currentDateStr())
            .fontSize(12).fontColor('#CCFFFFFF')
            .margin({ top: 4, left: 18 })

          Blank()

          // 4×4 应用图标网格（EMUI 默认顺序 · 鸿蒙系统符号）
          Column({ space: 20 }) {
            // 第一行：设置、主题、华为商城、华为视频
            Row({ space: 16 }) {
              this.iconItem($r('sys.symbol.gearshape'), '#8E8E93', '设置')
              this.iconItem($r('sys.symbol.paintpalette'), '#FF9500', '主题')
              this.iconItem($r('sys.symbol.bag'), '#FF3B30', '华为商城')
              this.iconItem($r('sys.symbol.video'), '#FF9500', '华为视频')
            }.width('100%').justifyContent(FlexAlign.Center)
            // 第二行：音乐、生活服务、服务、应用市场
            Row({ space: 16 }) {
              this.iconItem($r('sys.symbol.music'), '#007AFF', '音乐')
              this.iconItem($r('sys.symbol.paintpalette'), '#FF9500', '生活服务')
              this.iconItem($r('sys.symbol.heart'), '#34C759', '服务')
              this.iconItem($r('sys.symbol.cart'), '#007AFF', '应用市场')
            }.width('100%').justifyContent(FlexAlign.Center)
            // 第三行：钱包、运动健康、手机管家、图库
            Row({ space: 16 }) {
              this.iconItem($r('sys.symbol.creditcard'), '#FF9500', '钱包')
              this.iconItem($r('sys.symbol.heart'), '#FF3B30', '运动健康')
              this.iconItem($r('sys.symbol.lock'), '#007AFF', '手机管家')
              this.iconItem($r('sys.symbol.picture'), '#5AC8FA', '图库')
            }.width('100%').justifyContent(FlexAlign.Center)
          }
          .width('100%').padding({ top: 10 })

          Blank()

          // 底部 Dock：5 个（电话、联系人、信息、浏览器、相机）
          Row({ space: 12 }) {
            this.iconItem($r('sys.symbol.phone'), '#34C759', '')
            this.iconItem($r('sys.symbol.person'), '#FF9500', '')
            this.iconItem($r('sys.symbol.message'), '#34C759', '')
            this.iconItem($r('sys.symbol.wifi'), '#AF52DE', '')
            this.iconItem($r('sys.symbol.camera'), '#8E8E93', '')
          }
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor('#33000000')
          .borderRadius(28)
          .margin({ bottom: 16 })

          // HarmonyOS 导航栏：返回三角、圆圈主页、方块多任务
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontColor([Color.White]).fontSize(18).width(36).height(36)
            Blank()
            SymbolGlyph($r('sys.symbol.circle'))
              .fontColor([Color.White]).fontSize(14).width(36).height(36)
            Blank()
            SymbolGlyph($r('sys.symbol.square'))
              .fontColor([Color.White]).fontSize(14).width(36).height(36)
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 8, bottom: 12 })
        }
        .width('100%').height('100%')
        .padding({ top: 8 })
        .hitTestBehavior(HitTestMode.None)
      }

      // ===== 4. 锁屏预览模拟层（Cuto 风格：时间在上，居中） =====
      if (this.previewMode === 'lock') {
        Column() {
          // 同桌面模拟层：不画假状态栏（真机顶部有系统状态栏），Cuto 的锁屏预览也只留时钟
          Blank()

          // 日期 + 大号时间（Cuto 风格：在上半部分居中）
          Column({ space: 6 }) {
            Text(this.currentDateStr())
              .fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .textShadow({ radius: 4, color: '#88000000', offsetX: 0, offsetY: 1 })
            Text(this.currentTimeShort())
              .fontSize(78).fontWeight(FontWeight.Lighter)
              .fontColor(Color.White)
              .fontFamily('HarmonyOS Sans')
              .textShadow({ radius: 10, color: '#99000000', offsetX: 0, offsetY: 2 })
          }
          // 浅色壁纸上白色时钟会糊：加半透明暗色底，保证任何壁纸都可读
          .width('92%').alignItems(HorizontalAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor('#26000000')
          .borderRadius(24)
          .margin({ bottom: 200 })

          Blank()
        }
        .width('100%').height('100%')
        .padding({ top: 10 })
        .hitTestBehavior(HitTestMode.None)
      }

      // ===== 5. 左上角返回箭头（仅 UI 可见时显示） =====
      if (this.uiVisible) {
        Text('‹')
          .fontSize(32).fontColor(Color.White)
          .width(44).height(44).textAlign(TextAlign.Center)
          .backgroundColor('#55000000')
          .borderRadius(22)
          .position({ x: 14, y: 32 })
          .onClick(() => { this.onClose(); })
      }

      // ===== 6. 底部操作区（Cuto 式：一个磨砂胶囊放图标 + 一个主 CTA，仅 UI 可见时显示） =====
      if (this.uiVisible) {
        Column({ space: 12 }) {
          // 磨砂胶囊工具栏：收藏 / 预览模式（普通→桌面→锁屏）/ 保存并设为壁纸 / 编辑
          //  四件事全在一排，图标统一用系统符号（SymbolGlyph）+ 同一个白色 + 同一号字，
          //  不再混 emoji（emoji 自带颜色，四个图标永远凑不齐一套色调）。
          // 保存按钮是系统 SaveButton（写相册的临时授权必需），用 backgroundColor/iconColor/iconSize
          //  抹掉自带底色后，和这三个符号视觉一致。
          Row({ space: 28 }) {
            // 收藏：实心/描边靠颜色区分（未收藏=白，已收藏=主题红）
            SymbolGlyph($r('sys.symbol.heart'))
              .fontColor([this.isFav ? '#C9333D' : '#F2F2F5'])
              .fontSize(22)
              .onClick(() => {
                Haptics.light();
                // 写入本地收藏（带快照登记，云端图不在目录分页里也能在「最爱收藏」展示），
                // 返回父页面时由 onClose 回调刷新心形状态
                this.isFav = PreferenceUtil.toggleFavoriteItem(this.cur.id, this.cur);
                promptAction.showToast({ message: this.isFav ? '已收藏 ❤️' : '已取消收藏' });
              })

            // 预览模式切换（普通→桌面→锁屏→普通）
            Stack() {
              SymbolGlyph(this.previewMode === 'normal' ? $r('sys.symbol.picture')
                : (this.previewMode === 'home' ? $r('sys.symbol.phone') : $r('sys.symbol.lock')))
                .fontColor(['#F2F2F5'])
                .fontSize(22)
            }
            .onClick(() => {
              if (this.previewMode === 'normal') this.previewMode = 'home';
              else if (this.previewMode === 'home') this.previewMode = 'lock';
              else this.previewMode = 'normal';
            })

            // 铺满 / 适应切换：默认按屏幕比例自适应，这里供用户手动覆盖
            Text(this.fitCover ? '铺满' : '适应')
              .fontSize(13)
              .fontColor('#F2F2F5')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(13)
              .onClick(() => {
                // 用户手动切换后，后续图片回调不再自动改回
                this.userTouchedFit = true;
                this.fitCover = !this.fitCover;
                // 切换时重置缩放与位移：两种模式的平移边界不同，带着旧偏移会"跳一下"
                this.zoomScale = 1;
                this.offsetX = 0;
                this.offsetY = 0;
                promptAction.showToast({
                  message: this.fitCover ? '铺满（= 设为壁纸后的效果）' : '适应（完整显示整张图）'
                });
              })

            // 保存铺满图并给出设置步骤（锁屏/桌面在卡片里选）
            this.saveWallpaperButton()

            // 编辑
            SymbolGlyph($r('sys.symbol.paintpalette'))
              .fontColor(['#F2F2F5'])
              .fontSize(22)
              .onClick(() => { this.showEditor = true; })
          }
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor('#44000000')
          .borderRadius(28)
        }
        .position({ x: '50%', y: '100%' })
        .markAnchor({ x: '50%', y: '100%' })
        .margin({ bottom: 36 })
      }

      // ===== 7. 图片编辑器覆盖层 =====
      if (this.showEditor) {
        ImageEditor({
          wallpaper: this.cur,
          localImg: this.curLocalImg(),
          onClose: () => { this.showEditor = false; }
        })
      }

      // ===== 8. 设为壁纸引导（保存成功后出现，置于最上层） =====
      if (this.guideKind >= 0) {
        SetWallpaperGuidePanel({
          kind: this.guideKind,
          onClose: () => { this.guideKind = -1; }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
