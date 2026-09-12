import { describe, it, expect } from '@ohos/hypium';
import { CanvasState } from '../main/ets/common/editor/CanvasState';
import { CropView } from '../main/ets/common/editor/CropGeometry';
import { CropRect } from '../main/ets/common/editor/EditorModels';

/**
 * 画布状态回归测试（阶段 5 第 3c 步的数据契约）
 *
 * 这些断言描述的是 `CanvasView` 与 `ImageEditor` 之间的约定：
 * 选区坐标属于预览区坐标系、裁剪几何入参一次组装、贴边检测、切换比例与退出的复位语义。
 */
export default function canvasStateTest() {
  describe('canvasState', () => {
    it('is_cropping_requires_visible_and_non_empty_rect', 0, () => {
      const s: CanvasState = new CanvasState();
      expect(s.isCropping()).assertFalse();
      s.cropVisible = true;
      expect(s.isCropping()).assertFalse();
      s.cropW = 100;
      s.cropH = 100;
      expect(s.isCropping()).assertTrue();
    });

    it('crop_view_matches_editor_geometry_inputs', 0, () => {
      const s: CanvasState = new CanvasState();
      s.previewW = 360;
      s.previewH = 640;
      s.disp = { x: 0, y: 20, w: 360, h: 600, scale: 0.2 };
      s.cropScale = 1.5;
      s.cropOffsetX = 12;
      s.cropOffsetY = -8;
      s.cropAngle = 30;
      const v: CropView = s.cropView();
      expect(v.previewW).assertEqual(360);
      expect(v.previewH).assertEqual(640);
      expect(v.scale).assertEqual(1.5);
      expect(v.offsetX).assertEqual(12);
      expect(v.offsetY).assertEqual(-8);
      expect(v.angle).assertEqual(30);
      expect(v.disp.scale).assertEqual(0.2);
    });

    it('crop_rect_is_a_plain_view_of_selection', 0, () => {
      const s: CanvasState = new CanvasState();
      s.cropX = 10;
      s.cropY = 20;
      s.cropW = 30;
      s.cropH = 40;
      const r: CropRect = s.cropRect();
      expect(r.x).assertEqual(10);
      expect(r.y).assertEqual(20);
      expect(r.w).assertEqual(30);
      expect(r.h).assertEqual(40);
      // 改动状态后视图随之变化（不是快照）
      s.cropW = 50;
      expect(s.cropRect().w).assertEqual(50);
    });

    it('crop_slack_reports_all_four_directions', 0, () => {
      const s: CanvasState = new CanvasState();
      s.disp = { x: 0, y: 0, w: 360, h: 600, scale: 1 };
      s.cropX = 10;
      s.cropY = 20;
      s.cropW = 300;
      s.cropH = 500;
      const slack: number[] = s.cropSlack();
      expect(slack[0]).assertEqual(10);
      expect(slack[1]).assertEqual(20);
      expect(slack[2]).assertEqual(50);
      expect(slack[3]).assertEqual(80);
      // 贴边时余量为 0，拖动应该被夹住
      s.cropX = 0;
      s.cropY = 0;
      s.cropW = 360;
      s.cropH = 600;
      const tight: number[] = s.cropSlack();
      expect(tight[0]).assertEqual(0);
      expect(tight[1]).assertEqual(0);
      expect(tight[2]).assertEqual(0);
      expect(tight[3]).assertEqual(0);
    });

    it('reset_and_clear_semantics', 0, () => {
      const s: CanvasState = new CanvasState();
      s.cropScale = 2.5;
      s.cropOffsetX = 40;
      s.cropOffsetY = -40;
      s.cropAngle = 15;
      // 只重置图片变换，不影响选区
      s.cropW = 200;
      s.resetCropTransform();
      expect(s.cropScale).assertEqual(1);
      expect(s.cropOffsetX).assertEqual(0);
      expect(s.cropOffsetY).assertEqual(0);
      expect(s.cropAngle).assertEqual(0);
      expect(s.cropW).assertEqual(200);
      // 退出裁剪态：连比例一起复位
      s.cropVisible = true;
      s.cropRatio = '4:3';
      s.cropScale = 2;
      s.clearCrop();
      expect(s.cropVisible).assertFalse();
      expect(s.cropRatio).assertEqual('自由');
      expect(s.cropScale).assertEqual(1);
    });
  });
}
