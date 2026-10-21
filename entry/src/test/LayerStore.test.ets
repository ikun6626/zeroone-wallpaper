import { describe, it, expect } from '@ohos/hypium';
import { LayerStore, LayerKind, LayerSnapshot } from '../main/ets/common/editor/LayerStore';
import { TextItem, StickerItem } from '../main/ets/common/editor/EditorModels';

/**
 * 图层状态回归测试
 *
 * 覆盖阶段 5 第 2 步从 `ImageEditor` 抽出的规则：新增自动选中、删除后选中态修正、
 * 拖动只在实时标量上发生（不碰数组）、提交/放弃的语义、缩放范围夹取、快照隔离。
 */
export default function layerStoreTest() {
  describe('layerStore', () => {
    it('add_selects_new_layer_and_marks_dirty', 0, () => {
      const s: LayerStore = new LayerStore();
      s.markClean();
      const t: TextItem = { content: 'a', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 };
      const idx: number = s.addText(t);
      expect(idx).assertEqual(0);
      expect(s.selectedText()).assertEqual(0);
      expect(s.textCount()).assertEqual(1);
      expect(s.isDirty()).assertTrue();
      const st: StickerItem = { content: 'file://x.png', x: 10, y: 20, scale: 1, angle: 0 };
      expect(s.addSticker(st)).assertEqual(0);
      expect(s.selectedSticker()).assertEqual(0);
    });

    it('remove_fixes_selection_for_both_directions', 0, () => {
      const s: LayerStore = new LayerStore();
      s.addText({ content: 'a', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 });
      s.addText({ content: 'b', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 });
      s.addText({ content: 'c', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 });
      // 选中第 3 个（下标 2），删掉第 1 个（下标 0）→ 选中应前移为 1
      s.selectText(2);
      expect(s.removeText(0)).assertTrue();
      expect(s.selectedText()).assertEqual(1);
      expect(s.textCount()).assertEqual(2);
      // 删掉当前选中项 → 取消选中
      expect(s.removeText(1)).assertTrue();
      expect(s.selectedText()).assertEqual(-1);
      // 越界删除是无操作
      expect(s.removeText(9)).assertFalse();
      expect(s.textCount()).assertEqual(1);
    });

    it('drag_updates_live_offsets_without_touching_items', 0, () => {
      const s: LayerStore = new LayerStore();
      const t: TextItem = { content: 'a', color: '#FFFFFF', x: 100, y: 200, scale: 1, style: 0 };
      s.addText(t);
      s.beginDrag(LayerKind.TEXT, 0);
      s.updateDrag(30, -40);
      // 实时增量只反映在 liveDx/liveDy 上，item 本身没被改
      expect(s.liveDx(LayerKind.TEXT, 0)).assertEqual(30);
      expect(s.liveDy(LayerKind.TEXT, 0)).assertEqual(-40);
      expect(t.x).assertEqual(100);
      expect(t.y).assertEqual(200);
      // 其它图层不会拿到别人的增量
      expect(s.liveDx(LayerKind.TEXT, 1)).assertEqual(0);
      expect(s.liveDx(LayerKind.STICKER, 0)).assertEqual(0);
    });

    it('commit_drag_writes_back_and_resets', 0, () => {
      const s: LayerStore = new LayerStore();
      const t: TextItem = { content: 'a', color: '#FFFFFF', x: 100, y: 200, scale: 1, style: 0 };
      s.addText(t);
      s.markClean();
      s.beginDrag(LayerKind.TEXT, 0);
      s.updateDrag(30, -40);
      expect(s.commitDrag(100, 200)).assertTrue();
      expect(t.x).assertEqual(130);
      expect(t.y).assertEqual(160);
      expect(s.isDirty()).assertTrue();
      // 提交后实时增量归零、拖动状态清空
      expect(s.liveDx(LayerKind.TEXT, 0)).assertEqual(0);
      expect(s.dragKind()).assertEqual(LayerKind.NONE);
      // 没有在拖动时提交 → false（不会误写原地坐标）
      expect(s.commitDrag(0, 0)).assertFalse();
    });

    it('cancel_drag_discards_everything', 0, () => {
      const s: LayerStore = new LayerStore();
      const st: StickerItem = { content: 'file://a.png', x: 5, y: 6, scale: 1, angle: 0 };
      s.addSticker(st);
      s.beginDrag(LayerKind.STICKER, 0);
      s.updateDrag(99, 99);
      s.cancelDrag();
      expect(st.x).assertEqual(5);
      expect(st.y).assertEqual(6);
      expect(s.liveDx(LayerKind.STICKER, 0)).assertEqual(0);
      expect(s.dragKind()).assertEqual(LayerKind.NONE);
    });

    it('scale_setters_clamp_to_ui_range', 0, () => {
      const s: LayerStore = new LayerStore();
      s.addText({ content: 'a', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 });
      s.setTextScale(0, 99);
      expect(s.texts()[0].scale).assertEqual(4);
      s.setTextScale(0, 0.01);
      expect(s.texts()[0].scale).assertEqual(0.5);
      s.addSticker({ content: 'file://a.png', x: 0, y: 0, scale: 1, angle: 0 });
      s.setStickerScale(0, 99);
      expect(s.stickers()[0].scale).assertEqual(5);
      s.setStickerScale(0, -3);
      expect(s.stickers()[0].scale).assertEqual(0.4);
      // 越界下标是无操作，不抛错
      s.setTextScale(9, 2);
      s.setStickerAngle(9, 45);
    });

    it('text_props_update_and_mark_dirty', 0, () => {
      const s: LayerStore = new LayerStore();
      s.addText({ content: 'a', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 });
      s.markClean();
      s.setTextColor(0, '#C9333D');
      s.setTextStyle(0, 2);
      s.setTextContent(0, 'hello');
      const t: TextItem = s.texts()[0];
      expect(t.color).assertEqual('#C9333D');
      expect(t.style).assertEqual(2);
      expect(t.content).assertEqual('hello');
      expect(s.isDirty()).assertTrue();
      // 越界内容修改不生效也不抛错
      s.setTextContent(5, 'x');
      expect(s.texts().length).assertEqual(1);
    });

    it('snapshot_is_isolated_and_clear_resets_selection', 0, () => {
      const s: LayerStore = new LayerStore();
      const a: TextItem = { content: 'a', color: '#FFFFFF', x: 0, y: 0, scale: 1, style: 0 };
      s.addText(a);
      s.addSticker({ content: 'file://a.png', x: 0, y: 0, scale: 1, angle: 0 });
      const snap: LayerSnapshot = s.snapshot();
      expect(snap.texts.length).assertEqual(1);
      expect(snap.stickers.length).assertEqual(1);
      // 改动快照不影响 store
      snap.texts.pop();
      expect(s.textCount()).assertEqual(1);
      // 清空后选中态与拖动状态都归零
      s.beginDrag(LayerKind.TEXT, 0);
      s.clearTexts();
      expect(s.textCount()).assertEqual(0);
      expect(s.selectedText()).assertEqual(-1);
      expect(s.dragKind()).assertEqual(LayerKind.NONE);
      s.clearStickers();
      expect(s.stickerCount()).assertEqual(0);
      expect(s.selectedSticker()).assertEqual(-1);
    });
  });
}
