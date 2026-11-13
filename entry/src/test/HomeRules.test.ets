import { describe, it, expect } from '@ohos/hypium';
import { Wallpaper } from '../main/ets/model/Wallpaper';
import {
  formatCount, cardAspect, isWideWallpaper, HomeSeen,
  FeedComposer, FeedState, FeedPick, FeaturedSelector, SkeletonRule, FeedKeyRule
} from '../main/ets/common/home/HomeRules';
import { CursorRules, RecommendCursor, SeededOrder } from '../main/ets/common/home/HomeCursor';

function mk(id: string, w: number, h: number): Wallpaper {
  const x = new Wallpaper(id, id, '自然风景', '', 0, `t_${id}`);
  x.width = w;
  x.height = h;
  x.imageUrl = `https://cdn.example.com/${id}.jpg`;
  x.thumbUrl = `https://cdn.example.com/${id}_thumb.jpg`;
  return x;
}

export default function homeRulesTest() {
  describe('homeRulesTest', () => {
    it('formatCount', 0, () => {
      expect(formatCount(0)).assertEqual('');
      expect(formatCount(-3)).assertEqual('');
      expect(formatCount(7)).assertEqual('7');
      expect(formatCount(999)).assertEqual('999');
      expect(formatCount(1000)).assertEqual('1K');
      expect(formatCount(1200)).assertEqual('1.2K');
      expect(formatCount(12000)).assertEqual('12K');
      expect(formatCount(12345)).assertEqual('12.3K');
    });

    it('wideAndAspect', 0, () => {
      expect(isWideWallpaper(mk('a', 1920, 1080))).assertTrue();
      expect(isWideWallpaper(mk('b', 1200, 900))).assertTrue();
      expect(isWideWallpaper(mk('c', 1080, 1920))).assertFalse();
      expect(isWideWallpaper(mk('d', 0, 0))).assertFalse();
      expect(cardAspect(mk('e', 0, 0))).assertEqual(0.75);
      expect(cardAspect(mk('f', 1080, 1920))).assertEqual(0.5625);
    });

    it('dedupByUrlAndId', 0, () => {
      const a = mk('dupA', 1080, 1920);
      a.imageUrl = 'https://CDN.EXAMPLE.com/dup/x.jpg?token=1#p';
      const b = mk('dupB', 1080, 1920);
      b.imageUrl = 'https://cdn.example.com/dup/x.jpg?token=2';
      b.thumbUrl = 'https://cdn.example.com/dup/x.jpg';
      const seen = new HomeSeen();
      expect(seen.has(a)).assertFalse();
      seen.add(a);
      expect(seen.has(b)).assertTrue();
      // 相同 serverId 也要判重
      const c = mk('dupC', 1080, 1920);
      c.serverId = 88;
      const d = mk('dupD', 1080, 1920);
      d.serverId = 88;
      const seen2 = new HomeSeen();
      seen2.add(c);
      expect(seen2.has(d)).assertTrue();
    });

    it('feedBatchWideQuotaAndParity', 0, () => {
      const cands: Wallpaper[] = [];
      for (let i = 0; i < 10; i++) {
        cands.push(mk(`p${i}`, 1080, 1920));
      }
      cands.push(mk('w1', 1920, 1080));
      for (let i = 0; i < 7; i++) {
        cands.push(mk(`q${i}`, 1080, 1920));
      }
      cands.push(mk('w2', 1920, 1080));
      for (let i = 0; i < 20; i++) {
        cands.push(mk(`r${i}`, 1080, 1920));
      }
      const seen = new HomeSeen();
      const excluded = new HomeSeen();
      const state = new FeedState();
      const picks = FeedComposer.compose(cands, seen, excluded, state, 20);

      // 20 张基础 + 1 张满宽 => 21 格为奇数 => 补 1 张普通卡 = 21 张 / 22 格
      expect(picks.length).assertEqual(21);
      let wides = 0;
      for (let i = 0; i < picks.length; i++) {
        if (picks[i].wide) {
          wides++;
          expect(isWideWallpaper(picks[i].wallpaper)).assertTrue();
          if (i > 0) {
            expect(picks[i - 1].wide).assertFalse();
          }
        }
      }
      expect(wides).assertEqual(1);
      expect(picks[10].wide).assertTrue();
      // 总数（卡 + 满宽额外格）为偶数，末行不留单卡
      expect((picks.length + wides) % 2).assertEqual(0);
    });

    it('feedWideGapAtLeast8', 0, () => {
      const six = new FeedState();
      six.normalsSinceWide = 6;
      const picks6 = FeedComposer.compose([mk('w6', 1920, 1080)], new HomeSeen(), new HomeSeen(), six, 20);
      // 配额不足时横图整条跳过，绝不当普通窄卡（3:4 裁切）
      expect(picks6.length).assertEqual(0);

      const eight = new FeedState();
      eight.normalsSinceWide = 8;
      const picks8 = FeedComposer.compose([mk('w8', 1920, 1080)], new HomeSeen(), new HomeSeen(), eight, 20);
      expect(picks8.length).assertEqual(1);
      expect(picks8[0].wide).assertTrue();
      // 单张满宽 = 2 格，总格数为偶数，无需补卡
      expect((picks8.length + 1) % 2).assertEqual(0);
    });

    it('wideNeverDowngradedAndSpacingAtLeast8', 0, () => {
      // 多张横图：任意两张 wide 之间至少 7 张普通卡（索引差 >= 8），永不连续
      const cands: Wallpaper[] = [];
      for (let i = 0; i < 10; i++) {
        cands.push(mk(`n0_${i}`, 1080, 1920));
      }
      cands.push(mk('wide0', 1920, 1080));
      for (let i = 0; i < 10; i++) {
        cands.push(mk(`n1_${i}`, 1080, 1920));
      }
      cands.push(mk('wide1', 1920, 1080));
      for (let i = 0; i < 10; i++) {
        cands.push(mk(`n2_${i}`, 1080, 1920));
      }
      cands.push(mk('wide2', 1920, 1080));
      const picks = FeedComposer.compose(cands, new HomeSeen(), new HomeSeen(), new FeedState(), 40);
      let lastWide: number = -100;
      let wideCount: number = 0;
      for (let i = 0; i < picks.length; i++) {
        const p = picks[i];
        if (p.wide) {
          wideCount++;
          expect(isWideWallpaper(p.wallpaper)).assertTrue();
          expect(i - lastWide >= 8).assertTrue();
          lastWide = i;
        } else {
          // 任何普通卡都不能是横图（横图只能满宽出现）
          expect(isWideWallpaper(p.wallpaper)).assertFalse();
        }
      }
      expect(wideCount >= 2).assertTrue();
    });

    it('featuredAlways16AndRotationChangesDaily', 0, () => {
      const all: Wallpaper[] = [];
      for (let i = 0; i < FeaturedSelector.FIXED_IDS.length; i++) {
        all.push(mk(FeaturedSelector.FIXED_IDS[i], 1080, 1920));
      }
      for (let i = 0; i < 40; i++) {
        all.push(mk(`extra_${i}`, 1080, 1920));
      }
      const day1 = FeaturedSelector.select(all, '2026-11-07', [], 0, null);
      expect(day1.items.length).assertEqual(16);
      expect(day1.fixedIds.length).assertEqual(10);
      expect(day1.rotationIds.length).assertEqual(6);

      let uniq = 0;
      for (let i = 0; i < day1.items.length; i++) {
        let dup = false;
        for (let k = 0; k < i; k++) {
          if (day1.items[k].id === day1.items[i].id) {
            dup = true;
          }
        }
        if (!dup) {
          uniq++;
        }
      }
      expect(uniq).assertEqual(16);

      const day2 = FeaturedSelector.select(all, '2026-11-08', day1.rotationIds, 0, null);
      let overlap = 0;
      for (let i = 0; i < day2.rotationIds.length; i++) {
        if (day1.rotationIds.indexOf(day2.rotationIds[i]) >= 0) {
          overlap++;
        }
      }
      expect(overlap).assertEqual(0);

      // 换一批：固定位不变，轮换位与当前不同
      const batch1 = FeaturedSelector.select(all, '2026-11-07', day1.rotationIds, 1, null);
      let fixedStable = true;
      for (let i = 0; i < day1.fixedIds.length; i++) {
        if (batch1.fixedIds.indexOf(day1.fixedIds[i]) < 0) {
          fixedStable = false;
        }
      }
      expect(fixedStable).assertTrue();
      let batchOverlap = 0;
      for (let i = 0; i < batch1.rotationIds.length; i++) {
        if (day1.rotationIds.indexOf(batch1.rotationIds[i]) >= 0) {
          batchOverlap++;
        }
      }
      expect(batchOverlap).assertEqual(0);
    });

    it('featuredFixedConflictUsesBackup', 0, () => {
      const all: Wallpaper[] = [];
      for (let i = 0; i < FeaturedSelector.FIXED_IDS.length; i++) {
        all.push(mk(FeaturedSelector.FIXED_IDS[i], 1080, 1920));
      }
      for (let i = 0; i < FeaturedSelector.FIXED_BACKUP_IDS.length; i++) {
        all.push(mk(FeaturedSelector.FIXED_BACKUP_IDS[i], 1080, 1920));
      }
      for (let i = 0; i < 40; i++) {
        all.push(mk(`extra_${i}`, 1080, 1920));
      }
      // 日报占用第 1 个固定位：固定位必须改用备选，而不是重复出现
      const excluded = new HomeSeen();
      const hit = mk(FeaturedSelector.FIXED_IDS[0], 1080, 1920);
      excluded.add(hit);
      const plan = FeaturedSelector.select(all, '2026-11-07', [], 0, excluded);
      expect(plan.items.length).assertEqual(16);
      expect(plan.fixedIds.length).assertEqual(10);
      expect(plan.rotationIds.length).assertEqual(6);
      for (let i = 0; i < plan.items.length; i++) {
        expect(plan.items[i].id === hit.id).assertFalse();
      }
      // 备选池补位（FIXED_BACKUP_IDS[0] 应进入固定位）
      expect(plan.fixedIds.indexOf(FeaturedSelector.FIXED_BACKUP_IDS[0]) >= 0).assertTrue();
      // 换一批后仍 10 固定，且冲突图不回填
      const next = FeaturedSelector.select(all, '2026-11-07', plan.rotationIds, 1, excluded);
      expect(next.items.length).assertEqual(16);
      expect(next.fixedIds.length).assertEqual(10);
      for (let i = 0; i < next.items.length; i++) {
        expect(next.items[i].id === hit.id).assertFalse();
      }
    });

    it('skeletonRule', 0, () => {
      // 3 个灰块同处一个全宽段（内部三等分），2 列下也不会留第 4 格黑空
      expect(SkeletonRule.COUNT).assertEqual(3);
      expect(SkeletonRule.CROSS_COUNT).assertEqual(1);
    });

    it('seededOrderAndNextRound', 0, () => {
      const list: Wallpaper[] = [];
      for (let i = 0; i < 12; i++) {
        list.push(mk(`s${i}`, 1080, 1920));
      }
      const seed = CursorRules.seedOf('2026-11-07');
      const a = SeededOrder.apply(list, seed, 1);
      const b = SeededOrder.apply(list, seed, 1);
      // 同 seed + page 必须完全稳定
      for (let i = 0; i < a.length; i++) {
        expect(a[i].id === b[i].id).assertTrue();
      }
      // 换 seed 后顺序必须变化（不按原序重播）
      let same = 0;
      const c = SeededOrder.apply(list, seed + 7, 1);
      for (let i = 0; i < a.length; i++) {
        if (a[i].id === c[i].id) {
          same++;
        }
      }
      expect(same < a.length).assertTrue();

      const cur = new RecommendCursor();
      cur.seed = seed;
      cur.page = 3;
      cur.offset = 120;
      cur.round = 0;
      const n = CursorRules.nextRound(cur, '2026-11-07');
      expect(n.page).assertEqual(1);
      expect(n.offset).assertEqual(0);
      expect(n.round).assertEqual(1);
      expect(n.seed === cur.seed).assertFalse();
    });

    it('feedKeyUniqueAcrossRounds', 0, () => {
      // 同一 wallpaper.id 在两轮合法重复，但 UI key 必须不同
      let serial: number = 0;
      const keys: string[] = [];
      for (let round = 0; round < 2; round++) {
        for (let i = 0; i < 20; i++) {
          const p = new FeedPick();
          p.wallpaper = mk('same_id', 1080, 1920);
          p.key = FeedKeyRule.make(++serial);
          keys.push(p.key);
        }
      }
      // 40 个条目（跨两轮同 id）key 集合无重复
      let distinct: number = 0;
      for (let i = 0; i < keys.length; i++) {
        if (keys.indexOf(keys[i]) === i) {
          distinct++;
        }
      }
      expect(distinct).assertEqual(keys.length);
      // 首轮第 1 张与次轮第 1 张 key 不同
      expect(keys[0] === keys[20]).assertFalse();
      expect(keys[0].startsWith('feed_')).assertTrue();
    });

    it('cursorRules', 0, () => {
      const c = new RecommendCursor();
      c.seed = 77;
      c.page = 1;
      c.offset = 0;
      const n = CursorRules.next(c, 40);
      expect(n.page).assertEqual(2);
      expect(n.offset).assertEqual(40);
      expect(n.seed).assertEqual(77);
      const n2 = CursorRules.next(n, 0);
      expect(n2.page).assertEqual(3);
      expect(n2.offset).assertEqual(40);
    });
  });
}
