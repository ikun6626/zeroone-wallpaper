import { describe, it, expect } from '@ohos/hypium';
import { CanvasPresets, CanvasPreset, PresetIds, SafeArea } from '../main/ets/common/canvas/CanvasPresets';
import { Size, Rect } from '../main/ets/common/canvas/ViewTransform';

/**
 * 画布预设回归测试
 *
 * 覆盖阶段 5 "比例/模板"栏的数据契约：预设集合稳定、固定比例取"塞得进屏幕的最大同比例矩形"、
 * 尺寸不会超过屏幕、长边护栏生效、安全区按比例内缩。
 */
export default function canvasPresetsTest() {
  describe('canvasPresets', () => {
    it('preset_list_is_stable', 0, () => {
      const list: CanvasPreset[] = CanvasPresets.all();
      expect(list.length).assertEqual(5);
      expect(list[0].id).assertEqual(PresetIds.DEVICE);
      expect(list[1].id).assertEqual(PresetIds.SQUARE);
      expect(list[2].id).assertEqual(PresetIds.CLASSIC);
      expect(list[3].id).assertEqual(PresetIds.WIDE);
      expect(list[4].id).assertEqual(PresetIds.FREE);
      // 未知 id 回退到设备预设，不能抛错
      expect(CanvasPresets.byId('nope').id).assertEqual(PresetIds.DEVICE);
    });

    it('device_preset_follows_screen', 0, () => {
      const dev: Size = { width: 1080, height: 2340 };
      const s: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.DEVICE), dev);
      expect(s.width).assertEqual(1080);
      expect(s.height).assertEqual(2340);
      expect(CanvasPresets.isDevice(CanvasPresets.byId(PresetIds.DEVICE))).assertTrue();
      expect(CanvasPresets.isDevice(CanvasPresets.byId(PresetIds.FREE))).assertTrue();
      expect(CanvasPresets.isDevice(CanvasPresets.byId(PresetIds.SQUARE))).assertFalse();
    });

    it('fixed_ratio_inscribes_in_screen', 0, () => {
      const dev: Size = { width: 1080, height: 2340 };
      // 1:1 → 短边为边长
      const sq: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.SQUARE), dev);
      expect(sq.width).assertEqual(1080);
      expect(sq.height).assertEqual(1080);
      // 4:3 → 满宽 1080，高 810（不越出屏幕）
      const c: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.CLASSIC), dev);
      expect(c.width).assertEqual(1080);
      expect(c.height).assertEqual(810);
      // 16:9 → 满宽，高 607.5 → 608
      const w: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.WIDE), dev);
      expect(w.width).assertEqual(1080);
      expect(w.height).assertEqual(608);
      expect(w.width <= dev.width).assertTrue();
      expect(w.height <= dev.height).assertTrue();
    });

    it('ratio_holds_on_wide_screens_too', 0, () => {
      // 横屏设备（折叠屏展开等）：固定比例仍取最大内接矩形
      const dev: Size = { width: 2340, height: 1080 };
      const c: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.CLASSIC), dev);
      expect(c.width).assertEqual(1440);
      expect(c.height).assertEqual(1080);
      const sq: Size = CanvasPresets.sizeFor(CanvasPresets.byId(PresetIds.SQUARE), dev);
      expect(sq.width).assertEqual(1080);
      expect(sq.height).assertEqual(1080);
    });

    it('long_edge_guard_applies', 0, () => {
      const huge: Size = { width: 3000, height: 6000 };
      const limited: Size = CanvasPresets.sizeForExport(CanvasPresets.byId(PresetIds.DEVICE), huge, 4096);
      expect(limited.width).assertEqual(2048);
      expect(limited.height).assertEqual(4096);
      // 正常尺寸不受影响
      const normal: Size = CanvasPresets.sizeForExport(CanvasPresets.byId(PresetIds.DEVICE),
        { width: 1080, height: 2340 }, 4096);
      expect(normal.width).assertEqual(1080);
      expect(normal.height).assertEqual(2340);
    });

    it('safe_area_insets_proportionally', 0, () => {
      const dev: Size = { width: 1080, height: 2340 };
      const preset: CanvasPreset = CanvasPresets.byId(PresetIds.DEVICE);
      const r: Rect = CanvasPresets.safeRect(preset, dev);
      const safe: SafeArea = preset.safe;
      expect(r.x).assertClose(dev.width * safe.left, 1e-6);
      expect(r.y).assertClose(dev.height * safe.top, 1e-6);
      expect(r.width).assertClose(dev.width * (1 - safe.left - safe.right), 1e-6);
      expect(r.height).assertClose(dev.height * (1 - safe.top - safe.bottom), 1e-6);
      // 安全区必须真的在画布内部
      expect(r.x > 0 && r.y > 0).assertTrue();
      expect(r.x + r.width < dev.width).assertTrue();
      expect(r.y + r.height < dev.height).assertTrue();
    });
  });
}
