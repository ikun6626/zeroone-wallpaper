import { TextItem, StickerItem } from './EditorModels';

/**
 * LayerStore —— 图层状态容器（纯逻辑，不依赖 UI / 系统 API）
 *
 * 从 `ImageEditor` 抽出来的原因：1770 行的组件里，图层数组、选中态、拖动实时标量、
 * dirty 标记和渲染/手势混在一起，任何一处改动都难以单独验证。抽成 store 之后
 * 这些规则可以被单元测试直接覆盖（见 `entry/src/test/LayerStore.test.ets`）。
 *
 * 两条关键约定（此前的性能与正确性问题都出在这里）：
 *  1. **拖动中不写回数组**：`beginDrag/updateDrag` 只改实时标量，`commitDrag()` 才落进 item。
 *     每帧写数组会让 ForEach 重建整个列表（拖动黏、滑杆卡）。
 *  2. **删除要修选中态**：删掉的正是选中项 → 取消选中；删掉的是它前面的项 → 下标前移，
 *     否则选中框会跳到错误的图层上。
 */

export enum LayerKind {
  NONE = 0,
  TEXT = 1,
  STICKER = 2
}

/** 导出/回滚用的快照（数组为副本，item 为原对象引用） */
export interface LayerSnapshot {
  texts: TextItem[];
  stickers: StickerItem[];
}

/** 文字缩放范围（与 UI 滑杆 0.5~4 一致） */
const TEXT_SCALE_MIN: number = 0.5;
const TEXT_SCALE_MAX: number = 4;
/** 贴纸缩放范围（与 UI 滑杆 0.4~5 一致） */
const STICKER_SCALE_MIN: number = 0.4;
const STICKER_SCALE_MAX: number = 5;

export class LayerStore {
  private textList: TextItem[] = [];
  private stickerList: StickerItem[] = [];
  private textSel: number = -1;
  private stickerSel: number = -1;

  private dragKindValue: number = LayerKind.NONE;
  private dragIndexValue: number = -1;
  private dragDxValue: number = 0;
  private dragDyValue: number = 0;

  private dirtyFlag: boolean = false;

  // ==================== 读取 ====================

  /** 文字图层（供渲染读取；**不要**直接改字段，写操作一律走本类方法） */
  texts(): TextItem[] {
    return this.textList;
  }

  /** 贴纸图层（同上） */
  stickers(): StickerItem[] {
    return this.stickerList;
  }

  textCount(): number {
    return this.textList.length;
  }

  stickerCount(): number {
    return this.stickerList.length;
  }

  selectedText(): number {
    return this.textSel;
  }

  selectedSticker(): number {
    return this.stickerSel;
  }

  dragKind(): number {
    return this.dragKindValue;
  }

  dragIndex(): number {
    return this.dragIndexValue;
  }

  isDirty(): boolean {
    return this.dirtyFlag;
  }

  markDirty(): void {
    this.dirtyFlag = true;
  }

  markClean(): void {
    this.dirtyFlag = false;
  }

  /**
   * 实时位移增量：只有"正在被拖动的那一个图层"会拿到非零值，
   * 渲染时用 `item.x + store.liveDx(kind, index)` 即可，无需每帧改数组。
   */
  liveDx(kind: number, index: number): number {
    return (this.dragKindValue === kind && this.dragIndexValue === index) ? this.dragDxValue : 0;
  }

  /** 实时位移增量（纵向） */
  liveDy(kind: number, index: number): number {
    return (this.dragKindValue === kind && this.dragIndexValue === index) ? this.dragDyValue : 0;
  }

  // ==================== 文字 ====================

  /** 新增文字图层并选中，返回新下标 */
  addText(item: TextItem): number {
    this.textList.push(item);
    this.textSel = this.textList.length - 1;
    this.dirtyFlag = true;
    return this.textSel;
  }

  /** 删除文字图层（越界为无操作）；返回是否真的删了 */
  removeText(index: number): boolean {
    if (index < 0 || index >= this.textList.length) {
      return false;
    }
    this.textList.splice(index, 1);
    this.textSel = LayerStore.shiftSelection(this.textSel, index, this.textList.length);
    this.dirtyFlag = true;
    return true;
  }

  setTextScale(index: number, scale: number): void {
    const t: TextItem | undefined = this.textAt(index);
    if (t === undefined) {
      return;
    }
    t.scale = LayerStore.clampValue(scale, TEXT_SCALE_MIN, TEXT_SCALE_MAX);
    this.dirtyFlag = true;
  }

  setTextColor(index: number, color: string): void {
    const t: TextItem | undefined = this.textAt(index);
    if (t === undefined) {
      return;
    }
    t.color = color;
    this.dirtyFlag = true;
  }

  setTextStyle(index: number, style: number): void {
    const t: TextItem | undefined = this.textAt(index);
    if (t === undefined) {
      return;
    }
    t.style = style;
    this.dirtyFlag = true;
  }

  setTextContent(index: number, content: string): void {
    const t: TextItem | undefined = this.textAt(index);
    if (t === undefined) {
      return;
    }
    t.content = content;
    this.dirtyFlag = true;
  }

  /** 提交文字位置（拖动结束时调用） */
  commitTextMove(index: number, x: number, y: number): void {
    const t: TextItem | undefined = this.textAt(index);
    if (t === undefined) {
      return;
    }
    t.x = x;
    t.y = y;
    this.dirtyFlag = true;
  }

  // ==================== 贴纸 ====================

  /** 新增贴纸图层并选中，返回新下标 */
  addSticker(item: StickerItem): number {
    this.stickerList.push(item);
    this.stickerSel = this.stickerList.length - 1;
    this.dirtyFlag = true;
    return this.stickerSel;
  }

  /** 删除贴纸图层（越界为无操作）；返回是否真的删了 */
  removeSticker(index: number): boolean {
    if (index < 0 || index >= this.stickerList.length) {
      return false;
    }
    this.stickerList.splice(index, 1);
    this.stickerSel = LayerStore.shiftSelection(this.stickerSel, index, this.stickerList.length);
    this.dirtyFlag = true;
    return true;
  }

  setStickerScale(index: number, scale: number): void {
    const s: StickerItem | undefined = this.stickerAt(index);
    if (s === undefined) {
      return;
    }
    s.scale = LayerStore.clampValue(scale, STICKER_SCALE_MIN, STICKER_SCALE_MAX);
    this.dirtyFlag = true;
  }

  setStickerAngle(index: number, angle: number): void {
    const s: StickerItem | undefined = this.stickerAt(index);
    if (s === undefined) {
      return;
    }
    s.angle = angle;
    this.dirtyFlag = true;
  }

  /** 提交贴纸位置（拖动结束时调用） */
  commitStickerMove(index: number, x: number, y: number): void {
    const s: StickerItem | undefined = this.stickerAt(index);
    if (s === undefined) {
      return;
    }
    s.x = x;
    s.y = y;
    this.dirtyFlag = true;
  }

  // ==================== 拖动 ====================

  /** 开始拖动某个图层（会顺带选中它） */
  beginDrag(kind: number, index: number): void {
    if (kind === LayerKind.TEXT) {
      this.textSel = index;
    } else if (kind === LayerKind.STICKER) {
      this.stickerSel = index;
    }
    this.dragKindValue = kind;
    this.dragIndexValue = index;
    this.dragDxValue = 0;
    this.dragDyValue = 0;
  }

  /** 拖动中：只更新实时增量，**不碰数组** */
  updateDrag(dx: number, dy: number): void {
    if (this.dragKindValue === LayerKind.NONE) {
      return;
    }
    this.dragDxValue = dx;
    this.dragDyValue = dy;
  }

  /**
   * 提交拖动：把 `base + 增量` 写进图层，并复位拖动状态。
   * @returns 是否真的提交（没有在拖动时返回 false）
   */
  commitDrag(baseX: number, baseY: number): boolean {
    if (this.dragKindValue === LayerKind.NONE || this.dragIndexValue < 0) {
      return false;
    }
    const x: number = baseX + this.dragDxValue;
    const y: number = baseY + this.dragDyValue;
    if (this.dragKindValue === LayerKind.TEXT) {
      this.commitTextMove(this.dragIndexValue, x, y);
    } else {
      this.commitStickerMove(this.dragIndexValue, x, y);
    }
    this.resetDrag();
    return true;
  }

  /** 放弃拖动：图层保持原样（用于手势被系统打断的情况） */
  cancelDrag(): void {
    this.resetDrag();
  }

  // ==================== 选择与整体操作 ====================

  selectText(index: number): void {
    this.textSel = (index >= 0 && index < this.textList.length) ? index : -1;
  }

  selectSticker(index: number): void {
    this.stickerSel = (index >= 0 && index < this.stickerList.length) ? index : -1;
  }

  clearSelection(): void {
    this.textSel = -1;
    this.stickerSel = -1;
  }

  /** 清空全部图层（"清除贴纸"一类入口用） */
  clearStickers(): void {
    this.stickerList = [];
    this.stickerSel = -1;
    this.resetDrag();
    this.dirtyFlag = true;
  }

  clearTexts(): void {
    this.textList = [];
    this.textSel = -1;
    this.resetDrag();
    this.dirtyFlag = true;
  }

  /** 导出用快照：数组是副本，调用方改动不会影响 store */
  snapshot(): LayerSnapshot {
    const t: TextItem[] = [];
    for (let i = 0; i < this.textList.length; i++) {
      t.push(this.textList[i]);
    }
    const s: StickerItem[] = [];
    for (let i = 0; i < this.stickerList.length; i++) {
      s.push(this.stickerList[i]);
    }
    return { texts: t, stickers: s };
  }

  // ==================== 内部 ====================

  private textAt(index: number): TextItem | undefined {
    return (index >= 0 && index < this.textList.length) ? this.textList[index] : undefined;
  }

  private stickerAt(index: number): StickerItem | undefined {
    return (index >= 0 && index < this.stickerList.length) ? this.stickerList[index] : undefined;
  }

  private resetDrag(): void {
    this.dragKindValue = LayerKind.NONE;
    this.dragIndexValue = -1;
    this.dragDxValue = 0;
    this.dragDyValue = 0;
  }

  /** 删除一个元素后修正选中下标 */
  private static shiftSelection(sel: number, removed: number, remain: number): number {
    if (sel < 0) {
      return -1;
    }
    if (sel === removed) {
      return -1;
    }
    const next: number = sel > removed ? sel - 1 : sel;
    return next < remain ? next : -1;
  }

  private static clampValue(v: number, lo: number, hi: number): number {
    if (v < lo) {
      return lo;
    }
    return v > hi ? hi : v;
  }
}
