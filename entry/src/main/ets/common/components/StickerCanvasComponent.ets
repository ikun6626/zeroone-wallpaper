/**
 * ⚠️ 已废弃 / 无调用方（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：全工程已无任何调用方（grep StickerCanvasComponent 只命中本文件）。
 * 替代：贴纸编辑已由 StickerStudioPage（componentSnapshot 所见即所得合成）
 *       与 StickerBoardPage（多贴纸画板）承担。
 * 保留原因：项目无版本控制，删除不可恢复；先隔离观察。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */
import { image } from '@kit.ImageKit';
import matrix4 from '@ohos.matrix4';

/** 贴纸变换（导出映射用：中心位于预览区坐标比例 × 导出尺寸） */
export interface StickerTransform {
  /** 贴纸中心相对预览区左上角的偏移（vp） */
  centerX: number;
  centerY: number;
  scale: number;
  angleDeg: number;
}

/**
 * StickerCanvasComponent —— 贴纸手势编辑组件（背景 + 单张贴纸）
 *
 * 层级：底层背景图(Image) / 上层贴纸(Image)
 * 手势（GestureGroup 组合）：
 *  - PanGesture        单指平移（改贴纸 X/Y）
 *  - PinchGesture      双指缩放（限制 0.5x ~ 3.0x）
 *  - RotationGesture   双指旋转（任意角度，绕贴纸中心）
 * 变换：matrix4 组合 [ 平移到中心 → 旋转 → 缩放 → 回移(-w/2,-h/2) ]，
 *      与 WallpaperExporter 的导出矩阵语义一致。
 * 交互：贴纸外框虚线选中框；点背景空白取消选中。
 */
@Component
export struct StickerCanvasComponent {
  /** 背景图 PixelMap */
  bgImage: image.PixelMap | undefined = undefined;
  /** 贴纸 PixelMap（透明底） */
  sticker: image.PixelMap | undefined = undefined;
  /** 贴纸基准显示边长（vp） */
  baseSize: number = 180;
  /** 重置信号：外部自增该值可把贴纸恢复到画面正中（1:1、无旋转） */
  @Prop @Watch('onResetToken') resetToken: number = 0;
  /** 变换变化回调（供外部实时同步 / 导出映射） */
  onTransformChange: (t: StickerTransform) => void = () => {
  };

  // 阴影预览
  @Prop shadowEnabled: boolean = false;
  @Prop shadowOpacity: number = 0.3;
  @Prop shadowBlur: number = 8;
  @Prop shadowOffsetX: number = 0;
  @Prop shadowOffsetY: number = 4;
  // 调色预览（对贴纸和背景都生效）
  @Prop imgBrightness: number = 0;    // -0.5~0.5
  @Prop imgContrast: number = 0;      // -0.5~0.5
  @Prop imgWarmth: number = 0;        // -0.5~0.5

  /** 贴纸中心相对预览区中心偏移 */
  @State offX: number = 0;
  @State offY: number = 0;
  @State zoom: number = 1;
  @State angleDeg: number = 0;
  /** 是否处于编辑选中态（显示虚线框） */
  @State selected: boolean = false;
  /** 预览区尺寸 */
  @State areaW: number = 360;
  @State areaH: number = 600;

  /** 手势起始基准 */
  private baseOffX: number = 0;
  private baseOffY: number = 0;
  private baseScale: number = 1;
  private baseAngle: number = 0;

  /** 是否显示贴纸 */
  private hasSticker(): boolean {
    return this.sticker !== undefined;
  }

  /** 贴纸中心（预览区坐标） */
  private centerX(): number {
    return this.areaW / 2 + this.offX;
  }

  private centerY(): number {
    return this.areaH / 2 + this.offY;
  }

  /** 回调外部 */
  private emit(): void {
    const t: StickerTransform = {
      centerX: this.centerX(),
      centerY: this.centerY(),
      scale: this.zoom,
      angleDeg: this.angleDeg
    };
    this.onTransformChange(t);
  }

  /** 贴纸变换矩阵：平移(中心) × 旋转 × 缩放 × 平移(-w/2,-h/2) */
  private matrix() {
    const half: number = this.baseSize / 2;
    const cx: number = this.areaW / 2 + this.offX;
    const cy: number = this.areaH / 2 + this.offY;
    return matrix4.identity()
      .translate({ x: cx, y: cy, z: 0 })
      .rotate({ x: 0, y: 0, z: 1, angle: this.angleDeg })
      .scale({ x: this.zoom, y: this.zoom, z: 1 })
      .translate({ x: -half, y: -half, z: 0 });
  }

  aboutToAppear(): void {
    this.selected = true;
  }

  /** 外部重置信号：贴纸回到画面正中 */
  onResetToken(): void {
    this.offX = 0;
    this.offY = 0;
    this.zoom = 1;
    this.angleDeg = 0;
    this.selected = true;
    this.emit();
  }

  build() {
    Stack() {
      // ===== 底层背景 =====
      if (this.bgImage !== undefined) {
        Image(this.bgImage)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Fill)
          .brightness(1 + this.imgBrightness)
          .contrast(1 + this.imgContrast)
        // 色温叠色层：暖色=橙色，冷色=蓝色，0=透明
        if (this.imgWarmth !== 0) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.imgWarmth > 0
              ? `rgba(255,140,0,${this.imgWarmth * 0.3})`
              : `rgba(0,120,255,${-this.imgWarmth * 0.3})`)
            .hitTestBehavior(HitTestMode.None)
        }
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#1C1D22')
      }

      // ===== 贴纸层 =====
      if (this.sticker !== undefined) {
        Stack() {
          // 虚线选中框
          if (this.selected) {
            Column()
              .width(this.baseSize)
              .height(this.baseSize)
              .border({ width: 1.5, color: '#FF6B6B', style: BorderStyle.Dashed })
              .borderRadius(6)
          }
          // 贴纸图
          Image(this.sticker)
            .width(this.baseSize)
            .height(this.baseSize)
            .objectFit(ImageFit.Contain)
            .brightness(1 + this.imgBrightness)
            .contrast(1 + this.imgContrast)
        }
        .width(this.baseSize)
        .height(this.baseSize)
        .transform(this.matrix())
        .shadow(this.shadowEnabled
          ? {
            radius: this.shadowBlur,
            color: `rgba(0,0,0,${this.shadowOpacity})`,
            offsetX: this.shadowOffsetX,
            offsetY: this.shadowOffsetY
          }
          : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            // 单指平移
            PanGesture()
              .onActionStart(() => {
                this.selected = true;
                this.baseOffX = this.offX;
                this.baseOffY = this.offY;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.offX = this.baseOffX + e.offsetX;
                this.offY = this.baseOffY + e.offsetY;
                this.emit();
              }),
            // 双指缩放（0.5x ~ 3.0x）
            PinchGesture()
              .onActionStart(() => {
                this.selected = true;
                this.baseScale = this.zoom;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.zoom = Math.min(3.0, Math.max(0.5, this.baseScale * e.scale));
                this.emit();
              }),
            // 双指旋转
            RotationGesture()
              .onActionStart(() => {
                this.selected = true;
                this.baseAngle = this.angleDeg;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.angleDeg = this.baseAngle + e.angle;
                this.emit();
              })
          )
        )
        .onClick(() => {
          this.selected = true;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1C1D22')
    .onClick(() => {
      // 点空白：取消选中
      this.selected = false;
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.areaW = newValue.width as number;
      this.areaH = newValue.height as number;
      // 区域尺寸确定后立即回传一次变换，保证未拖动贴纸时导出位置也正确
      this.emit();
    })
  }
}
