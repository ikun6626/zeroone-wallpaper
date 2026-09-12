import { CanvasState } from './CanvasState';
import { LayerStore } from './LayerStore';

/**
 * EditorCanvasModel —— 画布组件的状态薄壳（阶段 5 第 3c 步）
 *
 * 存在的唯一理由：ArkUI 的 `@ObjectLink` 要求被观察的类上挂 `@Observed`，
 * 而 `CanvasState` / `LayerStore` 刻意保持"纯数据 + 纯计算、不挂装饰器"，
 * 这样它们才能被本地单元测试直接引用（那 13 个用例）。
 *
 * 所以这里做一层薄壳：只负责把两个纯对象"变成可观察的"，不添加任何业务规则。
 * 规则仍然写在被包裹的两个类里，单测继续有效。
 *
 * 用法（下一轮 CanvasView 的入参）：
 *   @ObjectLink model: EditorCanvasModel;   // 读写 model.canvas / model.layers
 *
 * 所有权约定：由 `ImageEditor` 持有唯一实例，`CanvasView` 只读写、不复制到本地 @State。
 */
@Observed
export class EditorCanvasModel {
  /** 画布与裁剪状态（预览尺寸、底图尺寸、显示矩形、选区、变换） */
  canvas: CanvasState = new CanvasState();
  /** 图层状态（文字/贴纸、选中态、拖动实时标量、dirty） */
  layers: LayerStore = new LayerStore();
}
