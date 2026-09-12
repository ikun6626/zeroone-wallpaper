import { describe, it, expect } from '@ohos/hypium';
import { ViewTransform, ViewMath, LayerMath, Rect, Size, Point } from '../main/ets/common/canvas/ViewTransform';

/**
 * 几何层回归测试
 *
 * 覆盖"预览 = 导出"的几何前提：cover 基准、绘制矩形、画布↔原图区域映射、
 * 平移夹紧、捏合缩放、归一化图层坐标与导出长边护栏。
 *
 * 这些用例是后续改造的安全网：裁剪重写、预览铺满、双导出模式都复用同一套函数，
 * 一旦改动破坏几何语义，这里会先红。
 */
export default function canvasGeometryTest() {
  describe('canvasGeometry', () => {
    // 典型的竖屏机型画布 + 一张 3:2 横图（最容易被"铺满"搞错的方向）
    const CW: number = 1080;
    const CH: number = 2340;
    const SW: number = 3000;
    const SH: number = 2000;

    it('coverScale_takes_the_larger_ratio', 0, () => {
      // 画布 1080/3000=0.36，2340/2000=1.17 → 取 1.17 才铺得满
      expect(ViewMath.coverScale(SW, SH, CW, CH)).assertClose(1.17, 1e-9);
      // 竖图在竖屏上只需要等比填满宽度
      expect(ViewMath.coverScale(2000, 4000, 1080, 2340)).assertClose(0.585, 1e-9);
    });

    it('drawRect_covers_canvas_and_is_centered', 0, () => {
      const t: ViewTransform = ViewTransform.identity();
      const d: Rect = ViewMath.drawRect(SW, SH, CW, CH, t);
      expect(d.width).assertClose(SW * 1.17, 1e-6);
      expect(d.height).assertClose(SH * 1.17, 1e-6);
      // 画布被完全覆盖：左边缘必须 <= 0，右边缘必须 >= 画布宽
      expect(d.x <= 0).assertTrue();
      expect(d.x + d.width >= CW).assertTrue();
      // 未平移时左右留白对称
      expect(d.x + d.width / 2).assertClose(CW / 2, 1e-6);
    });

    it('sourceRect_is_what_preview_shows', 0, () => {
      const t: ViewTransform = ViewTransform.identity();
      const r: Rect = ViewMath.sourceRect(SW, SH, CW, CH, t);
      // 竖屏画布从横图中裁出的是一块竖向区域，且水平居中
      expect(r.height).assertClose(2000, 1e-6);
      expect(r.width).assertClose(CW / 1.17, 1e-6);
      expect(r.x + r.width / 2).assertClose(SW / 2, 1e-6);
      expect(r.y).assertClose(0, 1e-6);
      // 区域不会越出原图
      expect(r.x >= 0 && r.x + r.width <= SW + 1e-6).assertTrue();
    });

    it('sourceRect_shrinks_when_zoomed_in', 0, () => {
      const t: ViewTransform = new ViewTransform(2, 0, 0);
      const r: Rect = ViewMath.sourceRect(SW, SH, CW, CH, t);
      const base: Rect = ViewMath.sourceRect(SW, SH, CW, CH, ViewTransform.identity());
      // 放大 2 倍 → 可见的原图区域宽高各减半
      expect(r.width).assertClose(base.width / 2, 1e-6);
      expect(r.height).assertClose(base.height / 2, 1e-6);
    });

    it('clamp_keeps_canvas_fully_covered', 0, () => {
      const t: ViewTransform = new ViewTransform(1, 99, -99);
      const c: ViewTransform = ViewMath.clamp(SW, SH, CW, CH, t);
      expect(c.offsetX).assertClose(ViewMath.maxOffsetX(SW, SH, CW, CH, t), 1e-9);
      expect(c.offsetY).assertClose(-ViewMath.maxOffsetY(SW, SH, CW, CH, t), 1e-9);
      // 夹紧后依然铺满
      const d: Rect = ViewMath.drawRect(SW, SH, CW, CH, c);
      expect(d.x <= 1e-6).assertTrue();
      expect(d.y <= 1e-6).assertTrue();
      expect(d.x + d.width >= CW - 1e-6).assertTrue();
      expect(d.y + d.height >= CH - 1e-6).assertTrue();
    });

    it('no_horizontal_slack_when_width_already_fits', 0, () => {
      // 1000×4000（1:4）按高度铺满后宽度正好等于画布宽 → 水平方向没有富余，不允许拖动
      const t: ViewTransform = ViewTransform.identity();
      expect(ViewMath.maxOffsetX(1000, 4000, CW, CH, t)).assertClose(0, 1e-9);
      // 纵向有富余（4320 > 2340），因此可以上下滑动构图
      expect(ViewMath.maxOffsetY(1000, 4000, CW, CH, t) > 0).assertTrue();
    });

    it('drag_converts_vp_to_px_before_normalizing', 0, () => {
      const t: ViewTransform = ViewTransform.identity();
      // 3 倍密度下拖 500vp = 1500px ≈ 1.39 个画布宽；水平富余上限 1.125，会被夹到上限
      const moved: ViewTransform = ViewMath.withDrag(SW, SH, CW, CH, t, 500, 0, 3);
      expect(moved.offsetX).assertClose(ViewMath.maxOffsetX(SW, SH, CW, CH, moved), 1e-9);
      // 小位移按 px 归一化：拖 30vp=90px，占画布宽 90/1080
      const small: ViewTransform = ViewMath.withDrag(SW, SH, CW, CH, t, 30, 0, 3);
      expect(small.offsetX).assertClose(90 / CW, 1e-9);
    });

    it('pinch_clamps_scale_and_reclamps_offset', 0, () => {
      const t: ViewTransform = new ViewTransform(1, 0.5, 0.5);
      const zoomed: ViewTransform = ViewMath.withPinch(SW, SH, CW, CH, t, 10, 1, 5);
      expect(zoomed.scale).assertClose(5, 1e-9);
      expect(zoomed.offsetX <= ViewMath.maxOffsetX(SW, SH, CW, CH, zoomed) + 1e-9).assertTrue();
      expect(zoomed.offsetY <= ViewMath.maxOffsetY(SW, SH, CW, CH, zoomed) + 1e-9).assertTrue();
      const zoomOut: ViewTransform = ViewMath.withPinch(SW, SH, CW, CH, t, 0.01, 1, 5);
      expect(zoomOut.scale).assertClose(1, 1e-9);
    });

    it('quarter_turns_swap_size_and_wrap_negative', 0, () => {
      const s: Size = ViewMath.orientedSize(3000, 2000, 1);
      expect(s.width).assertEqual(2000);
      expect(s.height).assertEqual(3000);
      expect(ViewMath.normalizeTurns(-1)).assertEqual(3);
      expect(ViewMath.normalizeTurns(5)).assertEqual(1);
      expect(ViewMath.orientedSize(3000, 2000, 2).width).assertEqual(3000);
    });

    it('identity_detection', 0, () => {
      expect(ViewTransform.identity().isIdentity()).assertTrue();
      expect(new ViewTransform(1.000001, 0, 0).isIdentity()).assertTrue();
      expect(new ViewTransform(1, 0, 0, 0, true, false).isIdentity()).assertFalse();
      expect(new ViewTransform(1, 0, 0, 1).isIdentity()).assertFalse();
    });

    it('layer_coordinates_round_trip', 0, () => {
      const p: Point = LayerMath.toCanvas(0.25, 0.75, CW, CH);
      expect(p.x).assertClose(270, 1e-9);
      expect(p.y).assertClose(1755, 1e-9);
      const back: Point = LayerMath.toNormalized(p.x, p.y, CW, CH);
      expect(back.x).assertClose(0.25, 1e-9);
      expect(back.y).assertClose(0.75, 1e-9);
    });

    it('layer_is_device_independent', 0, () => {
      // 同一归一化坐标在两种机型上等比落点 —— 这就是"换设备不漂移"
      const a: Point = LayerMath.toCanvas(0.4, 0.6, 1080, 2340);
      const b: Point = LayerMath.toCanvas(0.4, 0.6, 1284, 2778);
      expect(a.x / 1080).assertClose(b.x / 1284, 1e-9);
      expect(LayerMath.sizeToNormalized(LayerMath.sizeToCanvas(0.1, 1284), 1284)).assertClose(0.1, 1e-9);
      expect(LayerMath.clamp01(-3)).assertEqual(0);
      expect(LayerMath.clamp01(9)).assertEqual(1);
    });

    it('limit_long_edge_guards_memory', 0, () => {
      const big: Size = ViewMath.limitLongEdge(6000, 4000, 4096);
      expect(big.width).assertEqual(4096);
      expect(big.height).assertEqual(2731);
      const small: Size = ViewMath.limitLongEdge(1080, 2340, 4096);
      expect(small.width).assertEqual(1080);
      expect(small.height).assertEqual(2340);
    });

    it('maxPan_matches_cover_overscan', 0, () => {
      // 未放大：没有余量，手势只能用于下滑关闭
      expect(ViewMath.maxPan(1, 1080)).assertClose(0, 1e-9);
      expect(ViewMath.maxPan(0.5, 1080)).assertClose(0, 1e-9);
      // 放大 2 倍：四周各多出半屏
      expect(ViewMath.maxPan(2, 1080)).assertClose(540, 1e-9);
      expect(ViewMath.maxPan(3, 2340)).assertClose(2340, 1e-9);
      // 与 drawRect 的自洽性：放大后可用余量 == (绘制宽 - 画布宽) / 2
      const t: ViewTransform = new ViewTransform(2, 0, 0);
      const d: Rect = ViewMath.drawRect(1000, 4000, CW, CH, t);
      expect(ViewMath.maxPan(2, CW) * 2).assertClose(d.width - CW, 1e-9);
    });
  });
}
