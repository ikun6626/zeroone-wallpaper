import { Wallpaper } from '../../model/Wallpaper';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import request from '@ohos.request';
import { fileIo } from '@kit.CoreFileKit';
import { ImageEditor } from './ImageEditor';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { SetWallpaperGuidePanel, WallpaperKind } from './SetWallpaperGuide';
import { EditGuard } from '../utils/EditGuard';
import { CanvasSpec } from '../canvas/CanvasSpec';
import { ViewTransform, ViewMath } from '../canvas/ViewTransform';
import { composeCoverToJpeg } from '../editor/ImageComposer';

/** 最大缩放倍数 */
const MAX_SCALE: number = 4;
/** 双击放大后的倍数 */
const DOUBLE_SCALE: number = 2.5;
/** 下滑/左滑多少距离触发关闭 */
const DISMISS_THRESHOLD: number = 120;

/**
 * ImagePreview —— 全屏大图预览（Cuto 风格）
 *
 * 特性：
 *  - 纯黑背景 + 图片**铺满屏幕**（cover，与 Cuto 一致）：所见即壁纸实际效果
 *  - 左上圆形返回箭头；底部「设为锁屏/设为桌面」主 CTA + 半透明胶囊工具栏
 *  - 保存成功后弹出图库设置引导（三方应用无法直接换壁纸，见 SetWallpaperGuide）
 *  - 单击图片：工具栏/返回箭头在显示 ↔ 隐藏之间切换（沉浸式看图）
 *  - 双指捏合缩放；双击放大/还原；放大后单指拖动浏览
 *  - 未放大时左滑或下滑 → 带动画关闭
 *  - 保存比例可切换：铺满屏幕（按设备屏幕像素合成，默认）/ 原图比例（不裁切）
 *  - 预览模式：普通 → iOS 桌面 → iOS 锁屏（模拟壁纸实际效果）
 */
@Component
export struct ImagePreview {
  @Prop wallpaper: Wallpaper = new Wallpaper();
  localImg: Resource | undefined = undefined;
  onClose: () => void = () => {};

  /** 缩放 / 平移 / 关闭动画 */
  @State zoomScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State dismissX: number = 0;
  @State dismissY: number = 0;
  @State dismissOpacity: number = 1;
  @State remoteLoaded: boolean = false;
  @State remoteFailed: boolean = false;
  @State saving: boolean = false;
  @State showEditor: boolean = false;
  /** 保存比例：0 = 铺满屏幕（按画布合成）1 = 原图比例（原始文件，不裁切） */
  @State saveMode: number = 0;
  /** 预览区尺寸（vp）：由 onAreaChange 记录，用于夹紧平移与归一化换算 */
  @State frameW: number = 0;
  @State frameH: number = 0;
  /** 工具栏/返回箭头是否可见（单击图片切换） */
  @State uiVisible: boolean = true;
  /** 预览模式：normal / home / lock */
  @State previewMode: string = 'normal';
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
    // 进入预览时读取本地收藏状态，保证与首页/合辑/我的页面一致
    this.isFav = PreferenceUtil.isFavorite(this.wallpaper.id);
    this.startClockTicker();
    // 注册返回键处理：预览是覆盖层，返回键应关闭预览。
    // 此前没有这个拦截，用户按返回键会直接把 App 退出（真实且高频的体验事故）。
    this.backId = EditGuard.push((): boolean => {
      this.dismiss(true);
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
   * 按画布（= 手机屏幕像素）合成 JPEG —— "铺满屏幕"保存
   * @param srcPath 沙箱内的原图文件路径
   */
  private async composeCanvasRatio(srcPath: string): Promise<ArrayBuffer> {
    const canvas: CanvasSpec = CanvasSpec.fromDevice();
    const source: image.ImageSource = image.createImageSource(srcPath);
    let pm: image.PixelMap | undefined = undefined;
    try {
      pm = await source.createPixelMap();
      const info: image.ImageInfo = pm.getImageInfoSync();
      return await composeCoverToJpeg(pm, info.size.width, info.size.height,
        canvas.width, canvas.height, this.currentViewTransform(), 95);
    } finally {
      if (pm !== undefined) {
        pm.release();
      }
      source.release();
    }
  }

  /** 当前时间 HH:mm（状态栏用） */
  private currentTimeStr(): string {
    // 读取 nowTick 建立渲染依赖：分钟变化时定时器驱动重绘
    if (this.nowTick < 0) { return ''; }
    const d = new Date();
    const h = d.getHours().toString().padStart(2, '0');
    const m = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
  }

  /** 当前时间 H:mm（锁屏大号用） */
  private currentTimeShort(): string {
    // 读取 nowTick 建立渲染依赖：分钟变化时定时器驱动重绘
    if (this.nowTick < 0) { return ''; }
    const d = new Date();
    const h = d.getHours();
    const m = d.getMinutes().toString().padStart(2, '0');
    return `${h}:${m}`;
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
   * 主 CTA 按钮：设为锁屏 / 设为桌面
   * 说明：写系统相册必须有 SaveButton 的临时授权，普通 Text/Button 点击
   * 没有授权，createAsset 会直接抛权限错误，因此这里必须是安全控件。
   */
  @Builder
  setWallpaperButton(label: string, kind: number) {
    Column({ space: 4 }) {
      SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Capsule })
        .width(104)
        .height(36)
        .onClick((_: ClickEvent, result: SaveButtonOnClickResult) => {
          if (result === SaveButtonOnClickResult.SUCCESS && !this.saving) {
            this.saveToAlbum(kind);
          }
        })
      Text(label)
        .fontSize(11)
        .fontColor('#E6E6EB')
    }
  }

  /**
   * 保存比例切换胶囊
   *  - 铺满屏幕：按设备屏幕像素离屏合成，所见即所存（默认）
   *  - 原图比例：保留完整原图、不裁切不缩放
   */
  @Builder
  saveModePill(label: string, mode: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.saveMode === mode ? '#111114' : '#E6E6EB')
      .backgroundColor(this.saveMode === mode ? '#E6C07E' : '#44000000')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .onClick(() => { this.saveMode = mode; })
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

  /**
   * 关闭预览：按实际触发方向飞出
   * @param vertical true=下滑手势，图片向下飞出；false=左滑手势，图片向左飞出
   */
  private dismiss(vertical: boolean): void {
    animateTo({ duration: 180, curve: Curve.EaseIn }, () => {
      if (vertical) {
        this.dismissX = 0;
        this.dismissY = 600;
      } else {
        this.dismissX = -500;
        this.dismissY = 0;
      }
      this.dismissOpacity = 0;
    });
    setTimeout(() => { this.onClose(); }, 180);
  }

  /**
   * 保存到系统相册
   * @param guideKind 传入 WallpaperKind.LOCK/HOME 时表示“设为壁纸”意图：
   *                  保存成功后弹出设置引导；传 -1 表示单纯存图。
   */
  async saveToAlbum(guideKind: number): Promise<void> {
    if (this.saving) return;
    if (this.wallpaper.imageUrl.length === 0 && this.localImg === undefined) {
      promptAction.showToast({ message: '图片地址无效' });
      return;
    }
    this.saving = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const dest: string = `${ctx.filesDir}/zeroone_preview_${Date.now()}.jpg`;
    let tempCreated: boolean = false;
    try {
      if (this.wallpaper.imageUrl.length > 0) {
        const task: request.DownloadTask = await request.downloadFile(ctx, {
          'url': this.wallpaper.imageUrl, 'filePath': dest
        });
        await new Promise<void>((resolve, reject) => {
          task.on('complete', () => resolve());
          task.on('fail', () => reject(new Error('download fail')));
        });
      } else if (this.localImg !== undefined) {
        const content: Uint8Array = await ctx.resourceManager.getMediaContent(this.localImg);
        const file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        fileIo.writeSync(file.fd, content.buffer as ArrayBuffer);
        fileIo.closeSync(file);
      }
      tempCreated = true;

      // 保存比例：
      //  - 0 铺满屏幕：按设备屏幕像素离屏合成（cover + 当前缩放/平移 = 用户所见），
      //    存出来的图就是手机比例，设为壁纸不会被系统二次裁切；
      //  - 1 原图比例：直接落原始文件字节（完整原图、不裁切、不缩放）。
      // 此前只有一条路径——把原图原样拷进相册，于是"预览是手机比例、存下来还是原比例"。
      if (this.saveMode === 0) {
        const bytes: ArrayBuffer = await this.composeCanvasRatio(dest);
        const out = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(out.fd, bytes);
        fileIo.closeSync(out);
      }

      const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
      fileIo.copyFileSync(dest, file.fd);
      fileIo.closeSync(file);
      if (guideKind >= 0) {
        // 设为壁纸意图：保存成功后展示引导卡片（在 SaveButton 回调之外渲染）
        this.guideKind = guideKind;
      } else {
        promptAction.showToast({ message: '已保存到相册 📷' });
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
        if (this.localImg !== undefined && !this.remoteLoaded) {
          Image(this.localImg).width('100%').height('100%').objectFit(ImageFit.Cover)
        }
        if (this.wallpaper.imageUrl.length > 0 && !this.remoteFailed) {
          Image(this.wallpaper.imageUrl)
            .width('100%').height('100%').objectFit(ImageFit.Cover)
            .opacity(this.remoteLoaded ? 1 : 0)
            .onComplete(() => { this.remoteLoaded = true; })
            .onError(() => { this.remoteFailed = true; })
        }
      }
      .width('100%')
      .height('100%')
      .scale({ x: this.zoomScale, y: this.zoomScale })
      .translate({ x: this.offsetX + this.dismissX, y: this.offsetY + this.dismissY })
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
          // 拖动 / 下滑关闭 / 左滑关闭
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
              } else {
                // 判断方向：左滑优先；切换主轴时清零另一轴，避免残留位移
                if (Math.abs(e.offsetX) > Math.abs(e.offsetY)) {
                  this.dismissY = 0;
                  this.dismissX = Math.min(0, e.offsetX);
                  this.dismissOpacity = Math.max(0, 1 + this.dismissX / 400);
                } else {
                  this.dismissX = 0;
                  this.dismissY = Math.max(0, e.offsetY);
                  this.dismissOpacity = Math.max(0, 1 - this.dismissY / 400);
                }
              }
            })
            .onActionEnd(() => {
              if (this.zoomScale <= 1) {
                if (this.dismissY > DISMISS_THRESHOLD) {
                  // 下滑触发 → 向下飞出
                  this.dismiss(true);
                } else if (-this.dismissX > DISMISS_THRESHOLD) {
                  // 左滑触发 → 向左飞出
                  this.dismiss(false);
                } else {
                  animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
                    this.dismissX = 0;
                    this.dismissY = 0;
                    this.dismissOpacity = 1;
                  });
                }
              }
            })
        )
      )

      // ===== 3. 桌面预览模拟层（EMUI / HarmonyOS 经典桌面风格） =====
      if (this.previewMode === 'home') {
        Column() {
          // 状态栏：左 运营商信号 + 移动数据 | 右 电量 + 时间
          Row() {
            Text('📶 0.00K/s  4G').fontSize(12).fontColor(Color.White).fontWeight(FontWeight.Medium)
            Blank()
            Text('62%  🕑').fontSize(12).fontColor(Color.White)
          }
          .width('100%').height(28)
          .padding({ left: 18, right: 18 }).alignItems(VerticalAlign.Center)

          // 大号时间 + 右侧温度 + 日期
          Row() {
            Text(this.currentTimeShort())
              .fontSize(64).fontWeight(FontWeight.Lighter)
              .fontColor(Color.White)
              .fontFamily('HarmonyOS Sans')
              .textShadow({ radius: 6, color: '#88000000', offsetX: 0, offsetY: 1 })
            Text('下午')
              .fontSize(18).fontColor(Color.White)
              .margin({ left: 4, top: 20 })
            Blank()
            Column({ space: 2 }) {
              Text('☀️  15℃').fontSize(16).fontColor(Color.White)
              Text('🌤 17/7').fontSize(12).fontColor('#CCFFFFFF')
            }
          }
          .width('100%')
          .padding({ left: 18, right: 18 })

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
          // HarmonyOS 状态栏
          Row() {
            Text(this.currentTimeStr()).fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Medium)
            Blank()
            Text('📶 📡 🔋').fontSize(14).fontColor(Color.White)
          }
          .width('100%').height(30)
          .padding({ left: 18, right: 18 }).alignItems(VerticalAlign.Center)

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
          .width('100%').alignItems(HorizontalAlign.Center)
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

      // ===== 6. 底部操作区（设为壁纸主 CTA + 胶囊工具栏，仅 UI 可见时显示） =====
      if (this.uiVisible) {
        Column({ space: 12 }) {
          // ① 保存比例：默认"铺满屏幕"（手机壁纸效果），需要完整原图时切到"原图比例"
          Row({ space: 8 }) {
            this.saveModePill('铺满屏幕', 0)
            this.saveModePill('原图比例', 1)
          }

          // ② 主 CTA：设为锁屏 / 设为桌面
          // 壁纸 App 的核心转化动作就是“把它变成我的壁纸”，
          // 保存完就此结束会让用户以为“保存了=设置了”，所以这里必须有明确出口。
          Row({ space: 12 }) {
            this.setWallpaperButton('设为锁屏', WallpaperKind.LOCK)
            this.setWallpaperButton('设为桌面', WallpaperKind.HOME)
          }

          // ③ 胶囊工具栏
          Row({ space: 28 }) {
            // 收藏
            Text(this.isFav ? '❤️' : '🤍')
              .fontSize(22)
              .onClick(() => {
                // 写入本地收藏，返回父页面时由 onClose 回调刷新心形状态
                this.isFav = PreferenceUtil.toggleFavorite(this.wallpaper.id);
                promptAction.showToast({ message: this.isFav ? '已收藏 ❤️' : '已取消收藏' });
              })

            // 预览模式切换（普通→桌面→锁屏→普通）
            Stack() {
              Text(this.previewMode === 'normal' ? '👁' : (this.previewMode === 'home' ? '📱' : '🔒'))
                .fontSize(22)
            }
            .onClick(() => {
              if (this.previewMode === 'normal') this.previewMode = 'home';
              else if (this.previewMode === 'home') this.previewMode = 'lock';
              else this.previewMode = 'normal';
            })

            // 仅存图（SaveButton 安全控件）
            SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Circle })
              .width(44).height(44)
              .onClick((_: ClickEvent, result: SaveButtonOnClickResult) => {
                if (result === SaveButtonOnClickResult.SUCCESS && !this.saving) {
                  this.saveToAlbum(-1);
                }
              })

            // 编辑
            Text('✏️').fontSize(22)
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
          wallpaper: this.wallpaper,
          localImg: this.localImg,
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
