import { describe, it, expect } from '@ohos/hypium';
import { toggleFilter, toggleTexture, NO_FILTER, NO_TEXTURE } from '../main/ets/common/editor/FilterPipeline';

/**
 * 滤镜/纹理激活态回归测试（阶段 5 问题四）
 *
 * 规则来自非破坏式管线（底图 → 滤镜 → 纹理）：点当前项 = 取消、点别的项 = 换掉，
 * 绝不叠加 —— 旧实现"在当前图上再叠一层"会出现"复古点两次 = 两层复古"。
 */
export default function filterPipelineTest() {
  describe('filterPipeline', () => {
    it('same_filter_toggles_back_to_original', 0, () => {
      expect(toggleFilter(NO_FILTER, '复古')).assertEqual('复古');
      // 再点一次同一个 → 回原图色
      expect(toggleFilter('复古', '复古')).assertEqual(NO_FILTER);
    });

    it('switching_filters_replaces_instead_of_stacking', 0, () => {
      const afterRetro: string = toggleFilter(NO_FILTER, '复古');
      expect(afterRetro).assertEqual('复古');
      // 换一个滤镜是"替换"，不是叠加
      const afterMono: string = toggleFilter(afterRetro, '黑白');
      expect(afterMono).assertEqual('黑白');
      // 再点当前这个 → 回原图
      expect(toggleFilter(afterMono, '黑白')).assertEqual(NO_FILTER);
    });

    it('same_texture_toggles_off_and_switching_replaces', 0, () => {
      expect(toggleTexture(NO_TEXTURE, '纸纹')).assertEqual('纸纹');
      expect(toggleTexture('纸纹', '纸纹')).assertEqual(NO_TEXTURE);
      expect(toggleTexture('纸纹', '噪点')).assertEqual('噪点');
    });
  });
}
