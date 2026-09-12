import { describe, it, expect } from '@ohos/hypium';
import { CropView, CropSize, CropDrawTransform, cropOutputSize, cropDrawTransform, unprojectCrop } from '../main/ets/common/editor/CropGeometry';
import { CropRect, DispRect } from '../main/ets/common/editor/EditorModels';
import { LayerPoint } from '../main/ets/common/editor/LayerGeometry';

/**
 * 裁剪几何回归测试
 *
 * 覆盖这次修掉的三个真实 bug：
 *  1. 图片必须按"预览区"适配（disp），而不是按选区适配 —— 否则一改选区图片就自己跳；
 *  2. 逆变换必须包含"绕预览中心缩放"这一项 —— 否则放大/拖动过之后裁出来的不是看到的那块；
 *  3. 旋转要真正参与裁剪，而不是只做 UI 预览。
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
  });
}
