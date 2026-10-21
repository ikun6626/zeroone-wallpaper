import { CanvasState } from './CanvasState';
import { LayerStore } from './LayerStore';
import { TextItem, StickerItem } from './EditorModels';

/**
 * EditorCanvasModel —— 画布组件的状态薄壳（阶段 5 第 3c 步）
 *
 * 存在的唯一理由：ArkUI 的 `@ObjectLink` 要求被观察的类上挂 `@Observed`，
 * 而 `CanvasState` / `LayerStore` 刻意保持"纯数据 + 纯计算、不挂装饰器"，
 * 这样它们才能被本地单元测试直接引用（那 13 个用例）。
 *
 * 所以这里做两层薄壳：只负责把两个纯对象"变成可观察的"，不添加任何业务规则。
 * 规则仍然写在被包裹的两个类里，单测继续有效。
 *
 * 为什么需要两个**薄壳子类**（而不是只给容器挂 @Observed）：
 *  ArkUI V1 的观察是"一层一层来"的 —— 只给容器挂 @Observed 时，
 *  读 `model.canvas.cropX` 拿到的是未标记的 `CanvasState` 实例，它的属性写入不会被拦截
 *  （就是社区常说的"嵌套对象的每一层都要能观察"）。所以这里用两个空壳子类把
 *  `CanvasState` / `LayerStore` **标记**成可观察类型，容器只做入口。
 *  这和 ArkUI 自己给集合类型打标记的做法一致（如 `@Observed class ToolBarOptions extends Array<...>`）。
 *  其中图层壳子还多一个"刷新计数"（见下），画布壳子是真正空的。
 *
 * 用法（重要，3c/3d 落地时的实际写法）：
 *   // ImageEditor：只作为"唯一所有者 + 引用入口"，业务代码写 model.canvas.* / model.layers.*
 *   @State model: EditorCanvasModel = new EditorCanvasModel();
 *   // CanvasView：@ObjectLink 必须挂在**真正被改的两个对象**上（ArkUI V1 的观察按对象注册，
 *   //            挂在容器上观察不到嵌套属性的写入，拖动就会不跟手）
 *   @ObjectLink state: ObservableCanvasState;
 *   @ObjectLink layers: ObservableLayerStore;
 *
 * 所有权约定：由 `ImageEditor` 持有唯一实例，`CanvasView` 只读写、不复制到本地 @State。
 */

/** 可观察的画布状态薄壳：不含任何规则，规则全在 CanvasState 里 */
@Observed
export class ObservableCanvasState extends CanvasState {
}

/**
 * 可观察的图层状态薄壳：规则全在 LayerStore 里，这里只做两件事
 *  1. 把 LayerStore 标记成可观察（@Observed）；
 *  2. 每次数据改动后翻一次计数（tickValue），保证外层能收到刷新通知。
 *
 * 为什么需要 tick：ArkUI V1 只在"属性值真的变了"时才通知（SubscribableHandler.set 里
 * `Reflect.get(target, property) === newValue` 会直接 return），而文字/贴纸的
 * `x / scale / angle / color` 是**数组元素上的字段**（元素本身没有代理），改它们
 * 不会通知任何人 —— 表现就是"捏合缩放、双指旋转、滑杆调色要等下一次刷新才显示"。
 * 旧代码靠 `refreshTexts()`（换一个数组引用）来兜底，这里换成薄壳翻计数，
 * 效果一样但不用每帧重建整个图层列表。
 *
 * 注意：拖动中的实时位移仍然只写 `LayerStore.updateDrag()` 的标量（所有权规则 2 不变），
 * 这里只是让"改完了"这件事一定被听到。
 */
@Observed
export class ObservableLayerStore extends LayerStore {
  /** 变更计数（只用于触发刷新，不参与任何业务判断） */
  private tickValue: number = 0;

  tick(): number {
    return this.tickValue;
  }

  private bump(): void {
    this.tickValue++;
  }

  // ===== 以下都是 LayerStore 的公开写方法：转调父类后翻一次计数 =====

  addText(item: TextItem): number {
    const idx: number = super.addText(item);
    this.bump();
    return idx;
  }

  removeText(index: number): boolean {
    const ok: boolean = super.removeText(index);
    this.bump();
    return ok;
  }

  setTextScale(index: number, scale: number): void {
    super.setTextScale(index, scale);
    this.bump();
  }

  setTextColor(index: number, color: string): void {
    super.setTextColor(index, color);
    this.bump();
  }

  setTextStyle(index: number, style: number): void {
    super.setTextStyle(index, style);
    this.bump();
  }

  setTextContent(index: number, content: string): void {
    super.setTextContent(index, content);
    this.bump();
  }

  commitTextMove(index: number, x: number, y: number): void {
    super.commitTextMove(index, x, y);
    this.bump();
  }

  addSticker(item: StickerItem): number {
    const idx: number = super.addSticker(item);
    this.bump();
    return idx;
  }

  removeSticker(index: number): boolean {
    const ok: boolean = super.removeSticker(index);
    this.bump();
    return ok;
  }

  setStickerScale(index: number, scale: number): void {
    super.setStickerScale(index, scale);
    this.bump();
  }

  setStickerAngle(index: number, angle: number): void {
    super.setStickerAngle(index, angle);
    this.bump();
  }

  commitStickerMove(index: number, x: number, y: number): void {
    super.commitStickerMove(index, x, y);
    this.bump();
  }

  clearTexts(): void {
    super.clearTexts();
    this.bump();
  }

  clearStickers(): void {
    super.clearStickers();
    this.bump();
  }

  /** 父组件批量改完图层（如几何重映射）后会调它标脏：同样翻一次计数 */
  markDirty(): void {
    super.markDirty();
    this.bump();
  }

  /** 撤销/重做整体恢复：转调父类后翻计数 */
  restoreSnapshot(texts: TextItem[], stickers: StickerItem[]): void {
    super.restoreSnapshot(texts, stickers);
    this.bump();
  }
}

@Observed
export class EditorCanvasModel {
  /** 画布与裁剪状态（预览尺寸、底图尺寸、显示矩形、选区、变换） */
  canvas: ObservableCanvasState = new ObservableCanvasState();
  /** 图层状态（文字/贴纸、选中态、拖动实时标量、dirty） */
  layers: ObservableLayerStore = new ObservableLayerStore();
}
