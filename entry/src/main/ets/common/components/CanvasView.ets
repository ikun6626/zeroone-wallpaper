import { image } from '@kit.ImageKit';
import { TextItem, StickerItem, DispRect } from '../editor/EditorModels';
import { TEXT_COLORS } from '../editor/EditorConstants';
import { ObservableCanvasState, ObservableLayerStore } from '../editor/EditorCanvasModel';
import { LayerKind } from '../editor/LayerStore';

/**
 * 裁剪覆盖层配色（集中一处，方便以后做暗色模式/主题化）
 *
 * 之前全是硬编码白色，浅色图（天空、白墙）上选区框几乎看不见；
 * 现在按"可移动边框用黑色"来配：框与九宫格用黑，把手用**黑底白边**
 * （深色图上靠白边勾出轮廓，浅色图上靠黑底站得住）。
 */
const CROP_DIM_COLOR: string = '#73000000';
const CROP_FRAME_COLOR: string = '#111114';
const CROP_FRAME_WIDTH: number = 1.5;
const CROP_GRID_COLOR: string = '#80000000';
const CROP_HANDLE_FILL: string = '#111114';
const CROP_HANDLE_EDGE: string = '#FFFFFF';
const CROP_HANDLE_EDGE_WIDTH: number = 0.5;

/**
 * CanvasView —— 画布（阶段 5 第 3c 步：预览 Stack + 文字/贴纸图层 + 全部手势，从 ImageEditor 搬出来）
 *
 * 职责边界（接口契约见 RESTRUCTURE-PLAN.md「三之二、3c/3d 接口契约」）：
 *  1. 状态由 ImageEditor 持有：本组件只读写 `state` / `layers`，**不复制到本地 @State**；
 *  2. 拖动中的实时位移只写 `LayerStore.updateDrag()`（标量），手势结束才 `commitDrag()`，不直接改数组；
 *  3. 位图是只读输入（`pixelMap`），替换位图（旋转/裁剪/滤镜/纹理）仍然发生在父组件；
 *  4. 裁剪几何一律由父组件的回调去调 `CropGeometry` 的纯函数，这里只回报位移，不出现第二套坐标换算；
 *  5. 除渲染与手势外不持有任何业务规则（父组件仍是状态的唯一所有者）。
 *
 * 为什么入参是"画布状态 + 图层数据"两个对象，而不是一个 `EditorCanvasModel` 容器：
 *  ArkUI V1 的观察是**按对象注册**的 —— 组件只会成为自己 @ObjectLink/@State 的那个对象的订阅者
 *  （框架里由 ObservedObject.addOwningProperty 登记状态属性），**嵌套对象的属性写入不会通知外层容器**。
 *  要让拖动/裁剪跟手，@ObjectLink 必须挂到真正被改的那两个对象上（也就是契约里的 state / layers）。
 *
 * 关于"手势基准"：dragBaseX/dragBaseY/baseScale/baseAngle 是**手势开始那一刻**的快照，
 * 不参与渲染、只服务于一次手势，所以用普通字段而不是 @State —— 它们不是状态的副本。
 *
 * 单位与坐标：预览区坐标系（vp），由父组件的 `onAreaChange` 写进 `state.previewW/previewH`。
 */
@Component
export struct CanvasView {
  /** 画布状态：预览尺寸、底图尺寸、显示矩形、整套裁剪状态（见 common/editor/CanvasState.ets） */
  @ObjectLink state: ObservableCanvasState;
  /** 图层数据：文字/贴纸 + 选中态 + 拖动实时标量（见 common/editor/LayerStore.ets） */
  @ObjectLink layers: ObservableLayerStore;
  /**
   * 当前位图（Image 组件的数据源）
   *
   * 用 @Link 而不是契约里写的 @Prop：ArkUI V1 的 @Prop 会对 Object 值做**深拷贝**
   * （SynchedPropertyOneWayPU.copyObject → deepCopyObject），而 PixelMap 是原生对象，
   * 深拷贝出来的是一个空壳（原型还在、native 句柄没了），Image 会画不出东西。
   * @Link 直接共享父组件那一份（不拷贝），语义上仍然是"单向流入"：
   * 本组件**只读**，替换位图（旋转/裁剪/滤镜/纹理）一律发生在父组件。
   */
  @Link pixelMap: image.PixelMap | undefined;
  /** 当前工具（'crop' 等），裁剪态分支要用 */
  @Prop tool: string = 'transform';
  /**
   * 尺寸 / 角度的"实时值"（拉动滑杆期间生效）
   *
   * 为什么必须有：图层渲染读的是 `t.scale` / `s.scale`，而这些是普通对象字段，
   * `libs` 里的 setTextScale 只是改了字段值，**不会触发重绘** —— 所以拉动滑杆时
   * 文字/贴纸看起来"不动"。这里把实时值放进组件自己的 @State，
   * 渲染时优先读它，状态变化才会真正驱动重绘。
   */
  @State textSizeIdx: number = -1;
  @State textSizeLive: number = 1;
  @State stickerSizeIdx: number = -1;
  @State stickerSizeLive: number = 1;
  /** 贴纸旋转的实时值（把手拖动 / 双指旋转期间生效） */
  @State stickerAngleIdx: number = -1;
  @State stickerAngleLive: number = 0;
  /** 缩放滑杆的垂直偏移换算（纯函数，见 ImageEditor.sliderOffsetFor） */
  offsetForSlider: (baseSize: number, scale: number) => number =
    (baseSize: number, scale: number): number => (baseSize * scale) / 2 + 40;

  // ===== 回调：父组件仍是状态的唯一所有者 =====
  onSelectText: (idx: number) => void = () => {};
  onSelectSticker: (idx: number) => void = () => {};
  onRemoveText: (idx: number) => void = () => {};
  onRemoveSticker: (idx: number) => void = () => {};
  /** 图层数据变动后通知父组件（父组件据此触发刷新/标脏） */
  onLayersChanged: () => void = () => {};
  /** 裁剪手势（选区/图片变换）统一回报给父组件，几何仍在 CropGeometry 里 */
  onCropDragStart: () => void = () => {};
  onCropDragUpdate: (dx: number, dy: number) => void = () => {};
  onCropPinchStart: () => void = () => {};
  onCropPinchUpdate: (scale: number) => void = () => {};
  onCropHandleStart: () => void = () => {};
  onCropHandleDrag: (type: number, dx: number, dy: number) => void = () => {};

  /** 拖动基准：手势开始时的图层位置（vp 偏移） */
  private dragBaseX: number = 0;
  private dragBaseY: number = 0;
  /** 捏合基准：手势开始时的缩放 */
  private baseScale: number = 1;
  /** 贴纸旋转基准角（度） */
  private baseAngle: number = 0;
  /** 旋转把手拖动时的指针基准角（相对贴纸中心，度） */
  private rotatePointerBaseAngle: number = 0;
  /** 当前选中贴纸的全局中心（onAreaChange 记录，供 atan2 使用） */
  private stickerCenterX: number = 0;
  private stickerCenterY: number = 0;

  /** 贴纸当前渲染角度：交互中读实时值，其余时候读 store */
  private stickerAngleFor(s: StickerItem, idx: number): number {
    return this.stickerAngleIdx === idx ? this.stickerAngleLive : s.angle;
  }

  /** 归一化到 (-180, 180] */
  private normalizeAngle(angle: number): number {
    let next: number = angle;
    while (next > 180) {
      next -= 360;
    }
    while (next <= -180) {
      next += 360;
    }
    return next;
  }

  /** 0 / ±90 / ±180 附近 5° 内吸附，让“正放”更容易摆准 */
  private snapStickerAngle(angle: number): number {
    const targets: number[] = [-180, -90, 0, 90, 180];
    for (let i = 0; i < targets.length; i++) {
      if (Math.abs(angle - targets[i]) <= 5) {
        return targets[i];
      }
    }
    return angle;
  }

  /** 指针相对贴纸中心的角度（屏幕 Y 轴向下，结果与 rotate 的顺时针角一致） */
  private pointerAngle(globalX: number, globalY: number): number {
    return Math.atan2(globalY - this.stickerCenterY, globalX - this.stickerCenterX) * 180 / Math.PI;
  }

  /** 贴纸显示盒的实时半边长（65 = 130 / 2），用于定位旋转把手 */
  private stickerHalfSizeFor(s: StickerItem, idx: number): number {
    return 65 * (this.stickerSizeIdx === idx ? this.stickerSizeLive : s.scale);
  }

  /** 文字阴影（按风格：0=无 1=阴影 2=发光 3=描边） */
  private textShadowFor(t: TextItem): ShadowOptions | ShadowOptions[] {
    if (t.style === 1) {
      const s1: ShadowOptions = { radius: 4, color: '#66000000', offsetX: 1, offsetY: 2 };
      return s1;
    }
    if (t.style === 2) {
      const s2: ShadowOptions = { radius: 12, color: '#88FFFFFF', offsetX: 0, offsetY: 0 };
      return s2;
    }
    if (t.style === 3) {
      const s3: ShadowOptions[] = [
        { radius: 0, color: '#000000', offsetX: 1, offsetY: 0 },
        { radius: 0, color: '#000000', offsetX: -1, offsetY: 0 },
        { radius: 0, color: '#000000', offsetX: 0, offsetY: 1 },
        { radius: 0, color: '#000000', offsetX: 0, offsetY: -1 }
      ];
      return s3;
    }
    const s0: ShadowOptions = { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 };
    return s0;
  }

  /** 选区外压暗条（纯视觉，不拦截触摸） */
  @Builder
  cropDim(x: number, y: number, w: number, h: number) {
    Column()
      .width(w)
      .height(h)
      .backgroundColor(CROP_DIM_COLOR)
      .position({ x: x, y: y })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 把手的一条描边（角把手两条，边把手一条）：黑底白边，深浅图上都能看清 */
  @Builder
  handleBar(w: number, h: number, x: number, y: number) {
    Column()
      .width(w)
      .height(h)
      .backgroundColor(CROP_HANDLE_FILL)
      .border({ width: CROP_HANDLE_EDGE_WIDTH, color: CROP_HANDLE_EDGE })
      .position({ x: x, y: y })
  }

  /**
   * 文字图层渲染（阶段 5 第 3a 步抽出的 @Builder，3c 步整体搬进本组件）
   *
   * 只搬家不改逻辑：拖动中的实时位移走 LayerStore 标量（ForEach 不会重建整个列表），
   * 松手才 commitDrag() 提交进图层；缩放/换色/删除都经过 store 或父组件回调。
   */
  @Builder
  textLayer(t: TextItem, idx: number) {
    // 外层 Column：文字内容在上，选中态的缩放滑块在下，整体随 translate 移动
    Column({ space: 4 }) {
      Stack() {
        Text(t.content)
          // 显式用 vp：fontSize 传数字时默认单位是 fp（会跟随系统字体大小设置缩放），
          // 而导出按 vp→像素换算。用户把系统字体调大后，
          // 预览会变大、导出却不变 —— 这就是"所见非所得"。写死 vp 后两侧一致。
          // 优先读实时值：拖滑杆时 this.* 变化才会触发重绘（读 t.scale 不会）
          .fontSize(`${22 * (this.textSizeIdx === idx ? this.textSizeLive : t.scale)}vp`)
          .fontColor(t.color)
          .fontWeight(FontWeight.Bold)
          .textShadow(this.textShadowFor(t))
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 44, maxWidth: this.state.previewW - 48 })
        if (this.layers.selectedText() === idx) {
          Text('✕')
            .fontSize(14)
            .fontColor(Color.White)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FF6B6B')
            .borderRadius(11)
            .offset({ x: 8, y: -8 })
            // 22×22 的 ✕ 在真机上很难点中（尤其贴着边时）→ 放大触摸热区，视觉不变
            .responseRegion({ x: -12, y: -12, width: 46, height: 46 })
            .onClick(() => {
              this.onRemoveText(idx);
            })
        }
      }
      .alignContent(Alignment.TopEnd)
      // 选中态加虚线边框，提示可操作区域；未选中无视觉干扰
      .border(this.layers.selectedText() === idx
        ? { width: 1, color: '#FF6B6B', style: BorderStyle.Dashed } : { width: 0 })
      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    }
    // Block：强制拦截触摸，全透明背景不再穿透到下层 Image
    .hitTestBehavior(HitTestMode.Block)
    .backgroundColor(Color.Transparent)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    // 拖动中叠加实时位移：只改标量，ForEach 不会重建整个列表
    .translate({
      x: t.x + this.layers.liveDx(LayerKind.TEXT, idx),
      y: t.y + this.layers.liveDy(LayerKind.TEXT, idx)
    })
    .gesture(
      PanGesture()
        .onActionStart(() => {
          // beginDrag 顺带选中该项并复位实时标量（= 原来的 selectedText/base/清零三连）
          this.layers.beginDrag(LayerKind.TEXT, idx);
          this.dragBaseX = t.x;
          this.dragBaseY = t.y;
          this.onSelectText(idx);
        })
        .onActionUpdate((e: GestureEvent) => {
          // 按底图实际显示区域夹紧图层中心：disp 是图片在预览区里的真实矩形（vp），
          // 坐标轴上 translate 是相对预览中心的偏移，所以要先减掉 previewW/2。
          // 这样文字不会再被拖进 contain/cover 之外的灰色留白。
          const disp: DispRect = this.state.disp;
          const limitX: number = Math.max(0, disp.w) / 2;
          const limitY: number = Math.max(0, disp.h) / 2;
          const centerX: number = disp.x + disp.w / 2 - this.state.previewW / 2;
          const centerY: number = disp.y + disp.h / 2 - this.state.previewH / 2;
          // 拖动中只更新实时增量：此前是"改 t.x/t.y → refreshTexts()"，
          // 而 refreshTexts 会换掉数组引用，于是每一帧都重建全部文字节点。
          this.layers.updateDrag(
            Math.max(centerX - limitX - this.dragBaseX,
              Math.min(centerX + limitX - this.dragBaseX, e.offsetX)),
            Math.max(centerY - limitY - this.dragBaseY,
              Math.min(centerY + limitY - this.dragBaseY, e.offsetY)));
        })
        .onActionEnd(() => {
          // 松手才提交一次（store 内部同时复位实时增量）
          this.layers.commitDrag(this.dragBaseX, this.dragBaseY);
          this.onLayersChanged();
        })
    )
    .parallelGesture(
      PinchGesture()
        .onActionStart(() => {
          this.baseScale = t.scale;
        })
        .onActionUpdate((e: GestureEvent) => {
          // 缩放范围（0.5~4）由 LayerStore.setTextScale 统一钳制
          this.layers.setTextScale(idx, this.baseScale * e.scale);
          this.onLayersChanged();
        })
    )

    // 选中态滑杆：与文字本体同级的兄弟节点 → 只影响自身，不会挪动本体
    if (this.layers.selectedText() === idx) {
      Row({ space: 4 }) {
        Text('A').fontSize(10).fontColor('#999999')
        Slider({ value: t.scale, min: 0.5, max: 4, step: 0.1, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .blockColor('#FF6B6B')
          .selectedColor('#FF6B6B')
          .trackColor('#E0E0E0')
          .onChange((val: number) => {
            // 先写实时值（驱动本组件重绘），再写 store（供导出使用）
            this.textSizeIdx = idx;
            this.textSizeLive = val;
            this.layers.setTextScale(idx, val);
            this.onLayersChanged();
          })
        Text('A').fontSize(18).fontColor('#FF6B6B').fontWeight(FontWeight.Bold)
      }
      .width(150)
      // 拖动中滑杆要跟本体一起走：本体渲染用的是 t.x/t.y + 实时增量，这里必须加同一份
      .translate({
        x: t.x + this.layers.liveDx(LayerKind.TEXT, idx),
        y: t.y + this.layers.liveDy(LayerKind.TEXT, idx)
          + this.offsetForSlider(22, this.textSizeIdx === idx ? this.textSizeLive : t.scale)
      })

      // 选中态基础色板：六个圆点，白描边表示当前色；同样作为兄弟节点跟随实时位移
      Row({ space: 8 }) {
        ForEach(TEXT_COLORS, (c: string, colorIdx: number) => {
          Column()
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor(c)
            .border({
              width: 1,
              color: t.color === c ? Color.White : Color.Transparent
            })
            .onClick(() => {
              this.layers.setTextColor(colorIdx, c);
              this.onLayersChanged();
            })
        }, (c: string) => c)
      }
      .justifyContent(FlexAlign.Center)
      .width(150)
      .translate({
        x: t.x + this.layers.liveDx(LayerKind.TEXT, idx),
        y: t.y + this.layers.liveDy(LayerKind.TEXT, idx)
          + this.offsetForSlider(22, this.textSizeIdx === idx ? this.textSizeLive : t.scale) + 32
      })
    }
  }

  /**
   * 贴纸图层渲染（阶段 5 第 3b 步抽出的 @Builder，3c 步整体搬进本组件）
   *
   * 拖动只写实时标量、松手提交；缩放/旋转经 LayerStore 钳制与落库。
   */
  @Builder
  stickerLayer(s: StickerItem, idx: number) {
    Column({ space: 4 }) {
      Stack() {
        Image(s.content)
          // 同上：优先读实时值，否则拉滑杆时贴纸不会立刻变化
          .width(130 * (this.stickerSizeIdx === idx ? this.stickerSizeLive : s.scale))
          .height(130 * (this.stickerSizeIdx === idx ? this.stickerSizeLive : s.scale))
          .objectFit(ImageFit.Contain)
          // 贴纸自身旋转：拖把手 / 双指旋转期间优先读组件级实时值
          .rotate({ angle: this.stickerAngleFor(s, idx) })
        if (this.layers.selectedSticker() === idx) {
          Text('✕')
            .fontSize(14)
            .fontColor(Color.White)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor('#FF6B6B')
            .borderRadius(11)
            .position({ x: 90 * s.scale, y: -10 })
            // 同上：贴纸的 ✕ 也加大触摸热区
            .responseRegion({ x: -12, y: -12, width: 46, height: 46 })
            .onClick(() => {
              this.onRemoveSticker(idx);
            })
          // 旋转把手 + 摆正：放在贴纸上方，跟随本体实时位移
          Row({ space: 6 }) {
            Stack() {
              Text('⟳')
                .fontSize(16)
                .fontColor('#333333')
                .textAlign(TextAlign.Center)
            }
            .width(30)
            .height(30)
            .borderRadius(15)
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#DDDDDD' })
            .responseRegion({ x: -10, y: -10, width: 50, height: 50 })
            .gesture(
              PanGesture()
                .onActionStart((e: GestureEvent) => {
                  this.onSelectSticker(idx);
                  // 先复位实时槽位，再读 store 里的角度，避免读到上一次手势的残留值
                  this.stickerAngleIdx = -1;
                  this.stickerAngleLive = s.angle;
                  this.stickerAngleIdx = idx;
                  this.baseAngle = s.angle;
                  const finger: FingerInfo | undefined = e.fingerList.length > 0
                    ? e.fingerList[0] : undefined;
                  if (finger !== undefined) {
                    this.rotatePointerBaseAngle = this.pointerAngle(finger.globalX, finger.globalY);
                  }
                })
                .onActionUpdate((e: GestureEvent) => {
                  const finger: FingerInfo | undefined = e.fingerList.length > 0
                    ? e.fingerList[0] : undefined;
                  if (finger === undefined) {
                    return;
                  }
                  const delta: number = this.pointerAngle(finger.globalX, finger.globalY)
                    - this.rotatePointerBaseAngle;
                  const next: number = this.snapStickerAngle(
                    this.normalizeAngle(this.baseAngle + delta));
                  this.stickerAngleLive = next;
                  this.layers.setStickerAngle(idx, next);
                  this.onLayersChanged();
                })
                .onActionEnd(() => {
                  this.stickerAngleIdx = -1;
                })
            )
            Text('摆正')
              .fontSize(12)
              .fontColor('#333333')
              .height(30)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#FFFFFF')
              .borderRadius(15)
              .border({ width: 1, color: '#DDDDDD' })
              .onClick(() => {
                this.onSelectSticker(idx);
                this.stickerAngleIdx = idx;
                this.stickerAngleLive = 0;
                this.layers.setStickerAngle(idx, 0);
                this.onLayersChanged();
                this.stickerAngleIdx = -1;
              })
          }
          .position({
            x: this.stickerHalfSizeFor(s, idx) - 42,
            y: -26
          })
        }
      }
      // 选中态虚线边框
      .border(this.layers.selectedSticker() === idx
        ? { width: 1, color: '#FF6B6B', style: BorderStyle.Dashed } : { width: 0 })
      // 记录选中贴纸的全局中心：旋转把手拖动时用它算 atan2
      .onAreaChange((oldValue: Area, newValue: Area) => {
        if (this.layers.selectedSticker() === idx) {
          this.stickerCenterX = (newValue.globalPosition.x as number)
            + (newValue.width as number) / 2;
          this.stickerCenterY = (newValue.globalPosition.y as number)
            + (newValue.height as number) / 2;
        }
      })

      // 尺寸滑杆作为**兄弟节点**渲染：放进本体里会把本体撑高，导致选中时位置偏移。
    }
    .hitTestBehavior(HitTestMode.Block)
    .backgroundColor(Color.Transparent)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .translate({
      x: s.x + this.layers.liveDx(LayerKind.STICKER, idx),
      y: s.y + this.layers.liveDy(LayerKind.STICKER, idx)
    })
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.layers.beginDrag(LayerKind.STICKER, idx);
          this.dragBaseX = s.x;
          this.dragBaseY = s.y;
          this.onSelectSticker(idx);
        })
        .onActionUpdate((e: GestureEvent) => {
          // 夹紧到**底图实际显示区域**内：本体有 padding，且贴纸是 130x130 的 Contain 盒，
          // 所以半宽/半高用"显示盒一半 + 本体 padding"近似，避免贴纸边缘被拖出图片区域。
          // 贴纸被拉得比图片还大时，下限可能反过来；这里用 min/max 收敛成同一个边界，
          // 保证至少能停在图片中心一侧，而不是夹到越拖越远。
          const sDisp: DispRect = this.state.disp;
          const halfX: number = 65 * s.scale + 18;
          const halfY: number = 65 * s.scale + 12;
          const dispHalfW: number = Math.max(0, sDisp.w) / 2;
          const dispHalfH: number = Math.max(0, sDisp.h) / 2;
          const dispCenterX: number = sDisp.x + sDisp.w / 2 - this.state.previewW / 2;
          const dispCenterY: number = sDisp.y + sDisp.h / 2 - this.state.previewH / 2;
          let xMin: number = dispCenterX - dispHalfW + halfX;
          let xMax: number = dispCenterX + dispHalfW - halfX;
          let yMin: number = dispCenterY - dispHalfH + halfY;
          let yMax: number = dispCenterY + dispHalfH - halfY;
          xMin = Math.min(xMin, xMax);
          xMax = Math.max(xMin, xMax);
          yMin = Math.min(yMin, yMax);
          yMax = Math.max(yMin, yMax);
          const nx: number = Math.max(xMin, Math.min(xMax, this.dragBaseX + e.offsetX));
          const ny: number = Math.max(yMin, Math.min(yMax, this.dragBaseY + e.offsetY));
          this.layers.updateDrag(nx - this.dragBaseX, ny - this.dragBaseY);
        })
        .onActionEnd(() => {
          this.layers.commitDrag(this.dragBaseX, this.dragBaseY);
          this.onLayersChanged();
        })
    )
    .parallelGesture(
      PinchGesture()
        .onActionStart(() => {
          this.baseScale = s.scale;
        })
        .onActionUpdate((e: GestureEvent) => {
          // 缩放范围（0.4~5）由 LayerStore.setStickerScale 统一钳制
          this.layers.setStickerScale(idx, this.baseScale * e.scale);
          this.onLayersChanged();
        })
    )
    .parallelGesture(
      // 双指旋转贴纸：保留原有手势，渲染也走组件级实时值
      RotationGesture()
        .onActionStart(() => {
          this.onSelectSticker(idx);
          // 先复位实时槽位，再读 store 里的角度，避免读到上一次手势的残留值
          this.stickerAngleIdx = -1;
          this.stickerAngleLive = s.angle;
          this.stickerAngleIdx = idx;
          this.baseAngle = s.angle;
        })
        .onActionUpdate((e: GestureEvent) => {
          // 基准角 + 手势角（用累加会对不上手指，这是之前文字拖动踩过的坑）
          const next: number = this.snapStickerAngle(
            this.normalizeAngle(this.baseAngle + e.angle));
          this.stickerAngleLive = next;
          this.layers.setStickerAngle(idx, next);
          this.onLayersChanged();
        })
        .onActionEnd(() => {
          this.stickerAngleIdx = -1;
        })
    )

    // 选中态尺寸控件（兄弟节点）：精确可控且不影响本体位置
    if (this.layers.selectedSticker() === idx) {
      Column({ space: 2 }) {
        Row({ space: 4 }) {
          Text('□').fontSize(10).fontColor('#999999')
          Slider({ value: s.scale, min: 0.4, max: 5, step: 0.1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .blockColor('#FF6B6B')
            .selectedColor('#FF6B6B')
            .trackColor('#E0E0E0')
            .onChange((val: number) => {
              // 先写实时值（驱动重绘），再写 store
              this.stickerSizeIdx = idx;
              this.stickerSizeLive = val;
              this.layers.setStickerScale(idx, val);
              this.onLayersChanged();
            })
          Text('□').fontSize(18).fontColor('#FF6B6B').fontWeight(FontWeight.Bold)
        }
      }
      .width(170)
      // 同上：贴纸的大小控件要跟着贴纸本体一起移动
      .translate({
        x: s.x + this.layers.liveDx(LayerKind.STICKER, idx),
        // 用实时尺寸算偏移：否则拉大小时控件会与贴纸本体脱开
        y: s.y + this.layers.liveDy(LayerKind.STICKER, idx)
          + this.offsetForSlider(130, this.stickerSizeIdx === idx ? this.stickerSizeLive : s.scale)
      })
    }
  }

  build() {
    Stack() {
      // 裁剪态：图片在选区内可拖动/缩放，选区外不可见（苹果照片式）
      if (this.tool === 'crop' && this.state.cropVisible && this.pixelMap !== undefined) {
        // 选区内 clip 容器：只有这个区域内的图片可见
        // 图片可拖动/缩放（苹果照片式：手指在选区内拖动图片，选区框固定不动）
        Stack() {
          // 内层容器 = 整个预览区的坐标系：图片在这里按 Contain 适配（与 dispRect 一致），
          // 再整体反向平移，选区之外的部分由外层 clip 裁掉。
          // 此前图片是直接按"选区尺寸"适配的 —— 选区一变图片就自己跳，
          // 而且与裁剪换算对不上，这正是"框住的"和"裁出来的"不是一块的根因之一。
          Stack() {
            Image(this.pixelMap)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .translate({ x: this.state.cropOffsetX, y: this.state.cropOffsetY })
              .scale({ x: this.state.cropScale, y: this.state.cropScale })
              .rotate({ angle: this.state.cropAngle })
              .gesture(
                PanGesture()
                  .onActionStart(() => {
                    // 基准（cropPanBaseX/Y）由父组件记录
                    this.onCropDragStart();
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropDragUpdate(e.offsetX, e.offsetY);
                  })
              )
              .parallelGesture(
                PinchGesture()
                  .onActionStart(() => {
                    this.onCropPinchStart();
                  })
                  .onActionUpdate((e: GestureEvent) => {
                    this.onCropPinchUpdate(e.scale);
                  })
              )
          }
          .width(this.state.previewW)
          .height(this.state.previewH)
          .position({ x: -this.state.cropX, y: -this.state.cropY })
        }
        .width(this.state.cropW)
        .height(this.state.cropH)
        .position({ x: this.state.cropX, y: this.state.cropY })
        .clip(true)

        // 暗色遮罩：选区外完全不透明（盖住图片溢出部分）
        if (this.state.cropY > 0) {
          this.cropDim(0, 0, this.state.previewW, this.state.cropY)
        }
        if (this.state.cropY + this.state.cropH < this.state.previewH) {
          this.cropDim(0, this.state.cropY + this.state.cropH, this.state.previewW,
            this.state.previewH - this.state.cropY - this.state.cropH)
        }
        if (this.state.cropX > 0) {
          this.cropDim(0, this.state.cropY, this.state.cropX, this.state.cropH)
        }
        if (this.state.cropX + this.state.cropW < this.state.previewW) {
          this.cropDim(this.state.cropX + this.state.cropW, this.state.cropY,
            this.state.previewW - this.state.cropX - this.state.cropW, this.state.cropH)
        }

        // 选区框：白色细边框（苹果风格），纯视觉层
        // hitTestBehavior(None) 让触摸穿透到下层图片，由图片处理拖动
        // 选区框位置只能通过比例选择和把手拖拽改变（苹果照片式）
        Column()
          .width(this.state.cropW)
          .height(this.state.cropH)
          .border({ width: CROP_FRAME_WIDTH, color: CROP_FRAME_COLOR })
          .backgroundColor(Color.Transparent)
          .position({ x: this.state.cropX, y: this.state.cropY })
          .hitTestBehavior(HitTestMode.None)

        // 四角把手：黑底白边 L 型，内联以响应状态更新
        // 左上角
        Stack() {
          this.handleBar(20, 3, 0, 0)
          this.handleBar(3, 20, 0, 0)
        }
        .width(20)
        .height(20)
        .position({ x: this.state.cropX - 2, y: this.state.cropY - 2 })
        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
        .gesture(
          PanGesture()
            .onActionStart(() => {
              this.onCropHandleStart();
            })
            .onActionUpdate((e: GestureEvent) => {
              this.onCropHandleDrag(0, e.offsetX, e.offsetY);
            })
        )
        // 右上角
        Stack() {
          this.handleBar(20, 3, 0, 0)
          this.handleBar(3, 20, 17, 0)
        }
        .width(20)
        .height(20)
        .position({ x: this.state.cropX + this.state.cropW - 18, y: this.state.cropY - 2 })
        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
        .gesture(
          PanGesture()
            .onActionStart(() => {
              this.onCropHandleStart();
            })
            .onActionUpdate((e: GestureEvent) => {
              this.onCropHandleDrag(1, e.offsetX, e.offsetY);
            })
        )
        // 左下角
        Stack() {
          this.handleBar(20, 3, 0, 17)
          this.handleBar(3, 20, 0, 0)
        }
        .width(20)
        .height(20)
        .position({ x: this.state.cropX - 2, y: this.state.cropY + this.state.cropH - 18 })
        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
        .gesture(
          PanGesture()
            .onActionStart(() => {
              this.onCropHandleStart();
            })
            .onActionUpdate((e: GestureEvent) => {
              this.onCropHandleDrag(2, e.offsetX, e.offsetY);
            })
        )
        // 右下角
        Stack() {
          this.handleBar(20, 3, 0, 17)
          this.handleBar(3, 20, 17, 0)
        }
        .width(20)
        .height(20)
        .position({
          x: this.state.cropX + this.state.cropW - 18,
          y: this.state.cropY + this.state.cropH - 18
        })
        .responseRegion({ x: -12, y: -12, width: 44, height: 44 })
        .gesture(
          PanGesture()
            .onActionStart(() => {
              this.onCropHandleStart();
            })
            .onActionUpdate((e: GestureEvent) => {
              this.onCropHandleDrag(3, e.offsetX, e.offsetY);
            })
        )

        // 四边把手：黑底白边细条，内联以响应状态更新
        // 上边中点
        Column()
          .width(30).height(3).borderRadius(1.5).backgroundColor(CROP_HANDLE_FILL)
          .border({ width: CROP_HANDLE_EDGE_WIDTH, color: CROP_HANDLE_EDGE })
          .position({ x: this.state.cropX + this.state.cropW / 2 - 15, y: this.state.cropY - 2 })
          .responseRegion({ x: -18, y: -14, width: 66, height: 31 })
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.onCropHandleStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onCropHandleDrag(4, e.offsetX, e.offsetY);
              })
          )
        // 右边中点
        Column()
          .width(3).height(30).borderRadius(1.5).backgroundColor(CROP_HANDLE_FILL)
          .border({ width: CROP_HANDLE_EDGE_WIDTH, color: CROP_HANDLE_EDGE })
          .position({
            x: this.state.cropX + this.state.cropW - 2,
            y: this.state.cropY + this.state.cropH / 2 - 15
          })
          .responseRegion({ x: -14, y: -18, width: 31, height: 66 })
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.onCropHandleStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onCropHandleDrag(5, e.offsetX, e.offsetY);
              })
          )
        // 下边中点
        Column()
          .width(30).height(3).borderRadius(1.5).backgroundColor(CROP_HANDLE_FILL)
          .border({ width: CROP_HANDLE_EDGE_WIDTH, color: CROP_HANDLE_EDGE })
          .position({
            x: this.state.cropX + this.state.cropW / 2 - 15,
            y: this.state.cropY + this.state.cropH - 2
          })
          .responseRegion({ x: -18, y: -14, width: 66, height: 31 })
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.onCropHandleStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onCropHandleDrag(6, e.offsetX, e.offsetY);
              })
          )
        // 左边中点
        Column()
          .width(3).height(30).borderRadius(1.5).backgroundColor(CROP_HANDLE_FILL)
          .border({ width: CROP_HANDLE_EDGE_WIDTH, color: CROP_HANDLE_EDGE })
          .position({
            x: this.state.cropX - 2,
            y: this.state.cropY + this.state.cropH / 2 - 15
          })
          .responseRegion({ x: -14, y: -18, width: 31, height: 66 })
          .gesture(
            PanGesture()
              .onActionStart(() => {
                this.onCropHandleStart();
              })
              .onActionUpdate((e: GestureEvent) => {
                this.onCropHandleDrag(7, e.offsetX, e.offsetY);
              })
          )

        // 九宫格辅助线（2 横 2 竖，把选区分成 9 等份，辅助构图）
        Column()
          .width(this.state.cropW)
          .height(0.5)
          .backgroundColor(CROP_GRID_COLOR)
          .position({ x: this.state.cropX, y: this.state.cropY + this.state.cropH / 3 })
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(this.state.cropW)
          .height(0.5)
          .backgroundColor(CROP_GRID_COLOR)
          .position({ x: this.state.cropX, y: this.state.cropY + this.state.cropH * 2 / 3 })
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(0.5)
          .height(this.state.cropH)
          .backgroundColor(CROP_GRID_COLOR)
          .position({ x: this.state.cropX + this.state.cropW / 3, y: this.state.cropY })
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width(0.5)
          .height(this.state.cropH)
          .backgroundColor(CROP_GRID_COLOR)
          .position({ x: this.state.cropX + this.state.cropW * 2 / 3, y: this.state.cropY })
          .hitTestBehavior(HitTestMode.None)
      }
      if (!(this.tool === 'crop' && this.state.cropVisible)) {
        // 非裁剪态：图片不可移动
        Image(this.pixelMap)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      }

      // 裁剪态下隐藏文字/贴纸：它们不参与裁剪，且会浮在选区上方抢走拖动手势
      if (!(this.tool === 'crop' && this.state.cropVisible)) {
        // 文字叠加（多行 + 风格）—— 渲染内容见 @Builder textLayer()
        ForEach(this.layers.texts(), (t: TextItem, idx: number) => {
          this.textLayer(t, idx)
        }, (t: TextItem, idx: number) => idx.toString())

        // ===== 贴纸层（抠图/相册 PNG，可拖拽缩放旋转） =====
        // 贴纸层渲染内容见 @Builder stickerLayer()
        ForEach(this.layers.stickers(), (s: StickerItem, idx: number) => {
          this.stickerLayer(s, idx)
        }, (s: StickerItem, idx: number) => idx.toString())
      }
    }
    .width('100%')
    .height('100%')
  }
}
