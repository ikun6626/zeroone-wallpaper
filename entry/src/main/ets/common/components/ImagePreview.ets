import { Wallpaper } from '../../model/Wallpaper';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { ImageEditor } from './ImageEditor';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { WallpaperApi } from '../net/WallpaperApi';
import { AuthManager } from '../net/AuthManager';
import { ImageCache } from '../net/ImageCache';
import { Haptics } from '../utils/Haptics';
import { RemoteImage } from './RemoteImage';
import { LocalWallpapers } from '../constants/LocalWallpapers';
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
 *  - 纯黑背景 + 图片**默认「适应」（contain，完整显示整张图）**：
 *      横图/长图进竖屏时不会被裁掉人物或主体，用户可手动切「铺满」看壁纸效果
 *  - 左上圆形返回箭头；底部 Cuto 式磨砂胶囊：收藏 / 铺满适应 / 保存 / 编辑（按屏幕中线居中）
 *  - 单击图片：工具栏/返回箭头在显示 ↔ 隐藏之间切换（沉浸式看图）
 *  - 双指捏合缩放；双击放大/还原；放大后单指拖动浏览
 *  - 未放大时**左右滑切换上一张 / 下一张**（与首页 Hero 轮播一致）；下滑带动画关闭
 *  - 保存结果**跟随当前显示方式**（所见即所得）：
 *      铺满 → 按设备屏幕像素离屏合成（cover + 当前缩放/平移 = 用户所见），
 *             存出来就是手机比例；
 *      适应 → **直接存原图**（不裁切、不缩放、不重编码），保留原始构图与比例
 *  - 三方应用无法直接设壁纸：保存到相册后由用户在系统图库自行设置，本页不做模拟预览
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
  /**
   * 图片显示方式：true = Cover 铺满（= 设为壁纸后的真实效果）
   *                false = Contain 适应（完整显示整张图，上下留黑边）
   *
   * 默认「适应」：铺满在竖屏下会按高度放大、把横图左右各裁掉一大截
   * （实测 1024×576 横图在 1080×1920 屏只显示约 32%，右侧人脸被切），
   * 属于"看不到完整内容"的严重问题，所以默认改为完整显示；
   * 想要壁纸效果的用户仍可点底部「铺满」手动切换（切换后不再被自动改回）。
   *
   * 不再按「图片比例 vs 屏幕比例」自动决定默认值：之前那套自适应依赖
   * 异步图片回调拿尺寸，回调早于布局时会退回初始值（铺满）从而误裁，
   * 结果不可预期；默认固定为「适应」更安全、行为也跨机型一致。
   */
  @State fitCover: boolean = false;
  /** 收藏状态（简易本地存储） */
  @State isFav: boolean = false;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  private baseScale: number = 1;
  private baseOffsetX: number = 0;
  private baseOffsetY: number = 0;

  aboutToAppear(): void {
    // 内部展示项以入参初始化（之后左右滑切换只改 cur，不动父页面的 previewItem）
    this.cur = this.wallpaper;
    // 进入预览时读取本地收藏状态，保证与首页/合辑/我的页面一致
    this.isFav = PreferenceUtil.isFavorite(this.cur.id);
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
  }

  private clampZoom(value: number): number {
    return Math.min(MAX_SCALE, Math.max(1, value));
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

  /**
   * 工具栏上的保存按钮（与收藏、铺满适应、编辑同排）
   *
   * 说明：写系统相册必须有 SaveButton 的临时授权，普通 Text/Button 点击没有授权，
   * createAsset 会直接抛权限错误，所以这里必须是安全控件（不能自己画一个图标）；
   * 但外观是能改的 —— `SecurityComponentMethod`（SaveButtonAttribute 的基类）提供了
   * `backgroundColor / iconColor / iconSize / fontColor`，所以可以把它做成
   * "无底色 + 白色图标"，和旁边三个符号图标视觉统一。
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
          // 产品规则：保存图片必须登录；收藏等浏览行为仍允许游客使用
          if (!AuthManager.getInstance().requireLoginForSave()) {
            promptAction.showToast({ message: '请先登录后再保存图片' });
            return;
          }
          // 保存结果跟随当前显示方式（所见即所得）：铺满 → 按屏幕合成；适应 → 存原图。
          this.saveToAlbum();
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
   *   铺满 → 按设备屏幕像素合成 cover 成品（= 铺满预览所见）；
   *   适应 → **直接存原图**（不裁切 / 不缩放 / 不重编码）
   * 保存成功后由用户在系统图库自行设置壁纸，App 不做模拟预览或引导面板。
   */
  async saveToAlbum(): Promise<void> {
    if (this.saving) return;
    // 兜底拦截：任何调用路径都要求登录后才能保存
    if (!AuthManager.getInstance().requireLoginForSave()) {
      promptAction.showToast({ message: '请先登录后再保存图片' });
      return;
    }
    // 保存需登录（产品规则）：本地壁纸直接读随包资源，云端壁纸先下载
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
        // 存出来的图就是手机比例，在系统图库设为壁纸时不会被二次裁切。
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
        promptAction.showToast({ message: '已保存 · 原图，可在系统图库设为壁纸' });
      } else {
        promptAction.showToast({ message: '已保存 · 铺满，可在系统图库设为壁纸' });
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

      // ===== 2. 图片（默认「适应」完整显示；用户可点底部切「铺满」） =====
      // 注意：这里必须是 Contain 为默认 —— 横图在竖屏铺满会按高度放大，
      // 1080×1920 屏下 16:9 横图只能看到约 32% 宽度（人脸/主体被左右裁掉）。
      Stack() {
        // 云端壁纸：远程**原图**（imageUrl 优先，走三级缓存、按原始分辨率解码）；
        // 本地壁纸：随包内置资源。预览与保存都用原图，不用缩略图。
        RemoteImage({
          url: this.remoteSrc(),
          fallback: this.curLocalImg(),
          fit: this.fitCover ? ImageFit.Cover : ImageFit.Contain,
          fallbackFit: this.fitCover ? ImageFit.Cover : ImageFit.Contain,
          // 预览必须用原图：放大、保存都要原始清晰度，不能走卡片降采样链路
          fullSize: true
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

      // ===== 3. 左上角返回箭头（仅 UI 可见时显示） =====
      if (this.uiVisible) {
        Text('‹')
          .fontSize(32).fontColor(Color.White)
          .width(44).height(44).textAlign(TextAlign.Center)
          .backgroundColor('#55000000')
          .borderRadius(22)
          .position({ x: 14, y: 32 })
          .onClick(() => { this.onClose(); })
      }

      // ===== 4. 底部操作区（Cuto 式磨砂胶囊工具栏，仅 UI 可见时显示） =====
      if (this.uiVisible) {
        Column({ space: 12 }) {
          // 磨砂胶囊工具栏：收藏 / 铺满适应 / 保存 / 编辑
          //  四个动作全在一排，按屏幕中线居中；图标统一用系统符号（SymbolGlyph）+ 同一个白色 + 同一号字，
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

            // 铺满 / 适应切换：默认「适应」，用户可手动切「铺满」看壁纸效果
            Text(this.fitCover ? '铺满' : '适应')
              .fontSize(13)
              .fontColor('#F2F2F5')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(13)
              .onClick(() => {
                Haptics.light();
                this.fitCover = !this.fitCover;
                // 切换时重置缩放与位移：两种模式的平移边界不同，带着旧偏移会"跳一下"
                this.zoomScale = 1;
                this.offsetX = 0;
                this.offsetY = 0;
                promptAction.showToast({
                  message: this.fitCover ? '铺满（按屏幕比例合成）' : '适应（完整显示整张图）'
                });
              })

            // 保存（铺满 → 屏幕比例成品；适应 → 原图）
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

      // ===== 5. 图片编辑器覆盖层 =====
      if (this.showEditor) {
        ImageEditor({
          wallpaper: this.cur,
          localImg: this.curLocalImg(),
          onClose: () => { this.showEditor = false; }
        })
      }

    }
    .width('100%')
    .height('100%')
  }
}
