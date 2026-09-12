# 阶段 5：Cuto 式「先选壁纸/模板 → 轻编辑」重构方案

> 目标：把编辑器从「以一张图为中心的全能工具」改成「以画布为中心的轻编辑工作台」，
> 对齐 Cuto 的使用直觉：先看到壁纸效果 → 需要时再动手改一点。
> 前置条件已完成：画布按设备像素（`common/canvas/CanvasSpec`）、预览铺满、裁剪所见即所裁。

## 一、目标用户流程

```
首页 / 合辑 ──点图──▶ 全屏预览（铺满 = 壁纸效果，已实现）
                        ├─ 设为锁屏 / 设为桌面（保存 + 引导，已实现）
                        ├─ ❤ 收藏
                        └─ ✏️ 编辑 ──▶ 画布工作台（本阶段目标）
                                          ├─ 比例 / 模板：设备比例、1:1、4:3、16:9、自由
                                          ├─ 滤镜 / 纹理
                                          ├─ 文字：点画布直接打字，拖动跟手
                                          ├─ 贴纸：内置 / 相册导入（已能拖动缩放）
                                          ├─ 裁剪：8 把手 + 比例（已重写）
                                          └─ 导出：铺满屏幕 / 原图比例
```

与现状的差别：现在「编辑」直接进 1770 行的 `ImageEditor`（工具栏 + 图层 + 手势 + 导出全挤在一个组件里）；
目标是拆成「画布 + 动作条 + 按需面板」，并让图层状态独立成可测试的 store。

## 二、拆分后的结构

| 新文件 | 职责 | 从 `ImageEditor` 搬走的内容 |
|---|---|---|
| `common/editor/LayerStore.ets` | 图层数组、选中态、**实时拖动标量**、提交/回滚、dirty 标记 | `texts/stickers/selectedText/selectedSticker/textDrag*/refresh*` |
| `common/components/CanvasView.ets` | 只负责画布渲染与手势（拖动/捏合/旋转） | 预览 Stack 与三层 ForEach、手势 |
| `common/components/EditorActionBar.ets` | 底部动作条（切工具、切面板） | 底部 `tool` 切换与面板入口 |
| `common/components/panels/` | 裁剪 / 滤镜 / 文字 / 贴纸 各自一个面板组件 | 对应面板 UI 与回调 |
| `common/canvas/CanvasPresets.ets` | 比例/模板预设（目标尺寸 + 安全区） | 新增（当前比例逻辑散在裁剪与预览里） |

完成后 `ImageEditor.ets` 预期从 ~1770 行降到 300 行以内，只剩「组装 + 导出编排」。

## 三、分步实施（每步都能单独编译验证 + 独立提交）

| 步 | 内容 | 产出 | 预估 |
|---|---|---|---|
| 1 ✅ | `CanvasPresets`：设备比例 / 1:1 / 4:3 / 16:9 / 自由的纯模型 + 安全区（锁屏时钟区、桌面图标区） | 新文件 + 单测 | 1 天 |
| 2 ✅ | `LayerStore`：图层状态、选中态、实时拖动标量、提交/回滚、dirty | 新文件 + 单测 | 1 天 |
| 3a | 文字图层渲染抽成 `@Builder textLayer()`（同文件内搬，纯机械动作） | 重构提交 | 0.25 天 |
| 3b | 贴纸图层渲染抽成 `@Builder stickerLayer()`（同上） | 重构提交 | 0.25 天 |
| 3c | 预览 Stack + 手势搬进 `CanvasView` 组件（数据仍由 `ImageEditor` 传入） | 重构提交 | 0.5 天 |
| 3d | 数据源切换：`ImageEditor` 的 `@State texts/stickers/选中态` 换成 `LayerStore` | 重构提交 | 0.5 天 |
| 4 | 抽 `EditorActionBar` 与四个面板，`ImageEditor` 变壳 | 重构提交 | 1 天 |
| 5 | 入口改造：预览 → 工作台；旧 `ImageEditor` 保留为回退开关 | 行为变更提交 | 0.5 天 |
| 6 | 「轻编辑」默认态：进入时只给比例/模板与滤镜，其余收进面板 | 体验提交 | 0.5 天 |

## 四、原则与风险

- **第 3、4 步是纯搬家**：不改逻辑、不改视觉，只切分组件与数据流。搬家期间用现有 20 个几何单测兜底。

> 第 3 步进一步拆成 3a~3d 的原因：把 200 多行渲染代码一次性搬进新组件，一旦编译或视觉出问题，
> 很难判断是"搬家搬错了"还是"顺手改错了"。拆成四小步之后，每一步都能单独编译 + 单独回滚，
> 3a/3b 是纯机械的"剪切粘贴成 @Builder"，3c 才跨文件，3d 才真正换数据源。

## 三之二、3c/3d 接口契约（搬迁前先定死，避免边搬边改设计）

```ts
// common/components/CanvasView.ets
@Component
export struct CanvasView {
  /** 画布状态：预览尺寸、底图尺寸、显示矩形、整套裁剪状态（见 common/editor/CanvasState.ets） */
  @ObjectLink state: CanvasState;
  /** 图层数据：文字/贴纸 + 选中态 + 实时拖动标量（见 common/editor/LayerStore.ets） */
  @ObjectLink layers: LayerStore;
  /** 当前位图（Image 组件的数据源；只读，替换由父组件负责） */
  @Prop pixelMap: image.PixelMap | undefined;
  /** 当前工具（'crop' 等），裁剪态分支要用 */
  @Prop tool: string;
  /** 缩放滑杆的垂直偏移换算（纯函数，见 ImageEditor.sliderOffsetFor） */
  offsetForSlider: (baseSize: number, scale: number) => number;

  // 回调（父组件仍是状态的唯一所有者）
  onSelectText: (idx: number) => void;
  onSelectSticker: (idx: number) => void;
  onRemoveText: (idx: number) => void;
  onRemoveSticker: (idx: number) => void;
  /** 图层数据变动后通知父组件（父组件据此触发刷新/标脏） */
  onLayersChanged: () => void;
  /** 裁剪手势（选区/图片变换）统一回报给父组件，几何仍在 CropGeometry 里 */
  onCropDragStart: () => void;
  onCropDragUpdate: (dx: number, dy: number) => void;
  onCropPinchStart: () => void;
  onCropPinchUpdate: (scale: number) => void;
  onCropHandleStart: () => void;
  onCropHandleDrag: (type: number, dx: number, dy: number) => void;
}
```

**所有权规则（关键，违反就会出"拖动不跟手"或"选中框跳位"）：**

1. `CanvasState` 与 `LayerStore` 由 `ImageEditor` 持有，`CanvasView` 只读写它们，**不复制到本地 @State**。
2. 拖动中的实时位移只写 `LayerStore.updateDrag()`（标量），手势结束才 `commitDrag()`；`CanvasView` 不直接改数组。
3. 位图是只读输入；替换位图（旋转/裁剪/滤镜）仍然发生在父组件，通过 `pixelMap` 单向流入。
4. 裁剪几何一律调 `CropGeometry` 的纯函数，`CanvasView` 里不出现第二套坐标换算。
5. `@ObjectLink` 要求类上挂 `@Observed`：为此在 `CanvasState` 与 `LayerStore` 外用薄壳类装饰，**不改这两个类的内部规则**（它们的单测继续有效）。

**验收**：搬迁后 `hvigor … test` 39 个用例保持全绿；真机回归清单（预览铺满、双保存比例、裁剪所见即所裁、文字拖动跟手、导入贴纸可拖动缩放）逐条复验。
- **回退开关**：第 5 步切换入口时保留旧的 `ImageEditor` 直达路径，出问题可以立刻切回来。
- **不新建三套坐标**：画布、图层、裁剪继续共用 `common/canvas` 与 `CropGeometry` 的公式，新组件只消费，不重新推导。
- **每步都跑** `hvigor … test`（几何用例）与 `assembleHap`；新增源文件后必须 `clean` 一次再打包，否则增量编译可能漏编。
- **真机回归清单**沿用 `DELIVERY.md`：预览铺满、两种保存比例、裁剪所见即所裁、文字拖动跟手、导入贴纸可拖动缩放。

## 五、本阶段不做的事

- 不做模板商城、云模板、AI 生成。
- 不改云端数据模型（`wallpapers` 表保持不动）。
- 不做横屏与平板适配（壁纸场景锁竖屏）。
