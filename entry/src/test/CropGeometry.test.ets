import { describe, it, expect } from '@ohos/hypium';
import {
  CropView,
  CropSize,
  CropDrawTransform,
  cropOutputSize,
  cropDrawTransform,
  cropComposeTransform,
  unprojectCrop
} from '../main/ets/common/editor/CropGeometry';
import { CropRect, DispRect } from '../main/ets/common/editor/EditorModels';
import { LayerPoint } from '../main/ets/common/editor/LayerGeometry';

/**
 * 裁剪几何回归测试
 *
 * 覆盖这次修掉的三个真实 bug：
 *  1. 图片必须按"预览区"适配（disp），而不是按选区适配 —— 否则一改选区图片就自己跳；
 *  2. 逆变换必须包含"绕预览中心缩放"这一项 —— 否则放大/拖动过之后裁出来的不是看到的那块；
 *  3. 旋转要真正参与裁剪，而不是只做 UI 预览。
 * 另加两条：输出画布是"源图像素尺度"，绘制变换必须是同一尺度（否则裁完只剩左上角一块、四周全黑）。
 */
/** 1800×3000 的竖图在 360×640 预览区里的 contain 适配：scale = 0.2 */
const DISP: DispRect = { x: 0, y: 20, w: 360, h: 600, scale: 0.2 };
const PREVIEW_W: number = 360;
const PREVIEW_H: number = 640;

// ArkTS 不允许嵌套函数，辅助构造函数必须放在模块层
function view(scale: number, offsetX: number, offsetY: number, angle: number): CropView {
  return {
    disp: DISP, previewW: PREVIEW_W, previewH: PREVIEW_H,
    scale: scale, offsetX: offsetX, offsetY: offsetY, angle: angle
  };
}

export default function cropGeometryTest() {
  describe('cropGeometry', () => {

    it('output_size_follows_source_density', 0, () => {
      // 整张图（disp 全选）→ 输出就是原图尺寸
      const whole: CropRect = { x: DISP.x, y: DISP.y, w: DISP.w, h: DISP.h };
      const s: CropSize = cropOutputSize(whole, view(1, 0, 0, 0));
      expect(s.width).assertEqual(1800);
      expect(s.height).assertEqual(3000);
      // 放大 2 倍后同样大小的选区 → 只有原来一半的源像素（裁得更细，不是被放大）
      const s2: CropSize = cropOutputSize(whole, view(2, 0, 0, 0));
      expect(s2.width).assertEqual(900);
      expect(s2.height).assertEqual(1500);
    });

    it('no_transform_is_a_plain_offset', 0, () => {
      // 不缩放不旋转：画布原点 = 选区左上角，绘制平移 = 图片原点 − 选区原点
      const rect: CropRect = { x: 60, y: 120, w: 200, h: 300 };
      const t: CropDrawTransform = cropDrawTransform(rect, view(1, 0, 0, 0));
      expect(t.tx).assertClose(DISP.x - 60, 1e-9);
      expect(t.ty).assertClose(DISP.y - 120, 1e-9);
      expect(t.scale).assertClose(0.2, 1e-9);
      expect(t.radians).assertClose(0, 1e-9);
    });

    it('zoom_scales_about_preview_center', 0, () => {
      // 放大 2 倍时图片绕预览中心放大：原点移到 (-180, -280)
      const rect: CropRect = { x: 90, y: 170, w: 180, h: 300 };
      const t: CropDrawTransform = cropDrawTransform(rect, view(2, 0, 0, 0));
      expect(t.tx).assertClose(-180 - 90, 1e-9);
      expect(t.ty).assertClose(-280 - 170, 1e-9);
      expect(t.scale).assertClose(0.4, 1e-9);
      // 选区覆盖 180vp × 300vp → 0.4 vp/源像素 → 450 × 750 源像素
      const s: CropSize = cropOutputSize(rect, view(2, 0, 0, 0));
      expect(s.width).assertEqual(450);
      expect(s.height).assertEqual(750);
    });

    it('offset_shifts_the_image_not_the_frame', 0, () => {
      // 手指向右下拖动 40/40vp：图片整体位移，绘制平移随之增加
      const rect: CropRect = { x: 0, y: 20, w: 360, h: 600 };
      const t: CropDrawTransform = cropDrawTransform(rect, view(1, 40, 40, 0));
      expect(t.tx).assertClose(0 + 40, 1e-9);
      expect(t.ty).assertClose(0 + 40, 1e-9);
    });

    it('rotation_moves_the_origin', 0, () => {
      // 正方形绕中心顺时针 90°：左上角转到右上角
      const square: DispRect = { x: 0, y: 0, w: 100, h: 100, scale: 1 };
      const v: CropView = {
        disp: square, previewW: 100, previewH: 100,
        scale: 1, offsetX: 0, offsetY: 0, angle: 90
      };
      const t: CropDrawTransform = cropDrawTransform({ x: 0, y: 0, w: 100, h: 100 }, v);
      expect(t.tx).assertClose(100, 1e-9);
      expect(t.ty).assertClose(0, 1e-9);
      expect(t.radians).assertClose(Math.PI / 2, 1e-9);
    });

    it('unproject_is_the_inverse_of_draw_transform', 0, () => {
      const t: CropDrawTransform = cropDrawTransform({ x: 90, y: 170, w: 180, h: 300 },
        view(1.7, 25, -12, 33));
      // 取几个源图上的点，正向投影到画布，再逆投影回来必须回到原点位
      const samples: LayerPoint[] = [
        { x: 0, y: 0 }, { x: 900, y: 1500 }, { x: 1799, y: 2999 }, { x: 321.5, y: 777.25 }
      ];
      const cos: number = Math.cos(t.radians);
      const sin: number = Math.sin(t.radians);
      for (let i = 0; i < samples.length; i++) {
        const p: LayerPoint = samples[i];
        const ox: number = t.tx + t.scale * (p.x * cos - p.y * sin);
        const oy: number = t.ty + t.scale * (p.x * sin + p.y * cos);
        const back: LayerPoint = unprojectCrop(ox, oy, t);
        expect(back.x).assertClose(p.x, 1e-6);
        expect(back.y).assertClose(p.y, 1e-6);
      }
    });

    it('degenerate_inputs_stay_at_least_one_pixel', 0, () => {
      const tiny: CropRect = { x: 0, y: 0, w: 0.1, h: 0.1 };
      const s: CropSize = cropOutputSize(tiny, view(3, 0, 0, 0));
      expect(s.width >= 1).assertTrue();
      expect(s.height >= 1).assertTrue();
      // 缩放为 0（异常值）时按 1 处理，不能出现除零
      const t: CropDrawTransform = cropDrawTransform({ x: 0, y: 0, w: 100, h: 100 },
        view(0, 0, 0, 0));
      expect(t.scale > 0).assertTrue();
    });

    it('compose_transform_fills_the_whole_canvas', 0, () => {
      // 真实 bug：composeCropToPixelMap 用 vp 尺度的变换去画"源图像素尺度"的画布，
      // 图片只画到画布的三分之一不到，其余全是被 fillRect 铺的黑底（"裁完只剩左上角一块"）。
      // 这里直接验证：按 cropComposeTransform 变换后，源图四角必须盖住整张画布。
      const rect: CropRect = { x: 60, y: 120, w: 200, h: 300 };
      const v: CropView = view(1, 0, 0, 0);
      const size: CropSize = cropOutputSize(rect, v);
      // 情形一：无长边护栏（cap = 1）
      const t: CropDrawTransform = cropComposeTransform(rect, v, 1);
      const cos: number = Math.cos(t.radians);
      const sin: number = Math.sin(t.radians);
      const xs: number[] = [0, 1800, 0, 1800];
      const ys: number[] = [0, 0, 3000, 3000];
      let minX: number = 1e9;
      let maxX: number = -1e9;
      let minY: number = 1e9;
      let maxY: number = -1e9;
      for (let i = 0; i < xs.length; i++) {
        const ox: number = t.tx + t.scale * (xs[i] * cos - ys[i] * sin);
        const oy: number = t.ty + t.scale * (xs[i] * sin + ys[i] * cos);
        minX = Math.min(minX, ox);
        maxX = Math.max(maxX, ox);
        minY = Math.min(minY, oy);
        maxY = Math.max(maxY, oy);
      }
      expect(size.width).assertEqual(1000);
      expect(size.height).assertEqual(1500);
      expect(minX <= 1e-6).assertTrue();
      expect(minY <= 1e-6).assertTrue();
      expect(maxX >= size.width - 1e-6).assertTrue();
      expect(maxY >= size.height - 1e-6).assertTrue();
      // 情形二：触发长边护栏（cap = 0.5）后同样必须铺满
      const capped: CropDrawTransform = cropComposeTransform(rect, v, 0.5);
      expect(capped.scale).assertClose(0.5, 1e-9);
      expect(capped.tx).assertClose(t.tx * 0.5, 1e-9);
      expect(1800 * capped.scale + capped.tx >= size.width * 0.5 - 1e-6).assertTrue();
      expect(3000 * capped.scale + capped.ty >= size.height * 0.5 - 1e-6).assertTrue();
    });

    it('compose_transform_center_lands_on_the_selection_center', 0, () => {
      // 画布中心反查回源图像素，必须正好落在"选区中心"对应的源像素上
      const rect: CropRect = { x: 60, y: 120, w: 200, h: 300 };
      const v: CropView = view(1, 0, 0, 0);
      const size: CropSize = cropOutputSize(rect, v);
      const t: CropDrawTransform = cropComposeTransform(rect, v, 1);
      const center: LayerPoint = unprojectCrop(size.width / 2, size.height / 2, t);
      const ux: number = (rect.x + rect.w / 2 - v.disp.x) / v.disp.scale;
      const uy: number = (rect.y + rect.h / 2 - v.disp.y) / v.disp.scale;
      expect(center.x).assertClose(ux, 1e-6);
      expect(center.y).assertClose(uy, 1e-6);
    });
  });
}
