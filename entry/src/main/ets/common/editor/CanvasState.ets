import { DispRect, CropRect } from './EditorModels';
import { CropView } from './CropGeometry';

/**
 * CanvasState —— 画布侧状态（阶段 5 第 3c 步：跨组件传递的唯一状态对象）
 *
 * 为什么需要它：把"预览 Stack + 手势 + 图层渲染"搬进 `CanvasView` 组件时，如果逐个用
 * `@Prop/@Link` 传，要接二十来个参数，而且很容易踩"@Prop 单向拷贝导致拖动不更新"的坑。
 * 收敛成一个对象之后，`CanvasView` 只需要接收它 + 几个回调。
 *
 * 本类刻意保持**纯数据 + 纯计算**（不挂 @Observed、不 import 任何 @kit.*），
 * 这样既能被单元测试覆盖，将来在组件里包一层 @Observed 也不会影响这些规则。
 *
 * 单位约定：`disp` 是图片在预览区里的显示矩形（vp），由调用方用统一的 contain 适配算好后写入；
 * 裁剪选区与平移/缩放都是预览区坐标系（vp），与 `cropDrawTransform()` 的入参一致。
 */
export class CanvasState {
  /** 预览区尺寸（vp） */
  previewW: number = 360;
  previewH: number = 640;
  /** 当前底图像素尺寸 */
  imageW: number = 0;
  imageH: number = 0;
  /** 图片在预览区内的显示矩形（vp） */
  disp: DispRect = { x: 0, y: 0, w: 0, h: 0, scale: 1 };

  /** 是否处于裁剪态 */
  cropVisible: boolean = false;
  /** 裁剪比例文案（自由 / 1:1 / 4:3 / 3:4 / 16:9 / 9:16） */
  cropRatio: string = '自由';
  /** 裁剪选区（预览区坐标，vp） */
  cropX: number = 0;
  cropY: number = 0;
  cropW: number = 0;
  cropH: number = 0;
  /** 裁剪态下用户对图片的缩放 / 平移 / 旋转 */
  cropScale: number = 1;
  cropOffsetX: number = 0;
  cropOffsetY: number = 0;
  cropAngle: number = 0;

  /** 选区矩形（CropRect 视图，供几何函数使用） */
  cropRect(): CropRect {
    return { x: this.cropX, y: this.cropY, w: this.cropW, h: this.cropH };
  }

  /** 是否真的在裁剪（裁剪态且有有效选区） */
  isCropping(): boolean {
    return this.cropVisible && this.cropW > 0 && this.cropH > 0;
  }

  /** 裁剪几何入参：与 UI 使用的是同一套（见 CropGeometry.cropDrawTransform） */
  cropView(): CropView {
    return {
      disp: this.disp,
      previewW: this.previewW,
      previewH: this.previewH,
      scale: this.cropScale,
      offsetX: this.cropOffsetX,
      offsetY: this.cropOffsetY,
      angle: this.cropAngle
    };
  }

  /**
   * 选区四角是否还有余量（用于判断"能否再往外拖"）
   * 返回 [左, 上, 右, 下] 四个方向的可扩展量，0 表示已贴边。
   */
  cropSlack(): number[] {
    return [
      this.cropX - this.disp.x,
      this.cropY - this.disp.y,
      (this.disp.x + this.disp.w) - (this.cropX + this.cropW),
      (this.disp.y + this.disp.h) - (this.cropY + this.cropH)
    ];
  }

  /** 切换比例时重置图片变换（与既有行为一致：避免上次状态残留导致选区错位） */
  resetCropTransform(): void {
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropAngle = 0;
  }

  /** 退出裁剪态并复位（提交或取消后调用） */
  clearCrop(): void {
    this.cropVisible = false;
    this.cropRatio = '自由';
    this.resetCropTransform();
  }
}
