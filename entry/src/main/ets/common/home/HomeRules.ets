import { Wallpaper } from '../../model/Wallpaper';
import { LocalWallpapers } from '../constants/LocalWallpapers';

/**
 * HomeRules —— 首页 1.6.1 的纯规则层（无 UI、无网络，方便单测）
 *
 * 集中三个可替换策略：
 *  1. 精选 16 张：10 张固定 + 6 张按日期轮换（后端暂无固定位配置时的临时策略）；
 *  2. 推荐流批量：20 张为基础 + 满宽配额/奇偶补齐 + 跨批去重；
 *  3. 角标数字格式（<1000 原样；≥1000 一位小数 K，去尾零）。
 *
 * 注意：真正推荐算法（用户画像/多路召回/轮次换种子）属于 P1，
 * 本文件只负责当前 /wallpapers 兼容源也能满足的确定性规则。
 */

/** 角标数字格式：0/缺失由调用方决定不渲染，这里返回空串 */
export function formatCount(n: number): string {
  if (!Number.isFinite(n) || n <= 0) {
    return '';
  }
  if (n < 1000) {
    return String(Math.floor(n));
  }
  const k: number = n / 1000;
  let s: string = k.toFixed(1);
  if (s.endsWith('.0')) {
    s = s.substring(0, s.length - 2);
  }
  return `${s}K`;
}

/** 宽高比 ≥ 1.3 视为横图；尺寸缺失按竖图（由调用方按 3:4 渲染） */
export function isWideWallpaper(w: Wallpaper): boolean {
  if (w.width <= 0 || w.height <= 0) {
    return false;
  }
  return (w.width / w.height) >= 1.3;
}

/** 卡片宽高比（width/height）：尺寸缺失按 3:4 竖图 */
export function cardAspect(w: Wallpaper): number {
  if (w.width <= 0 || w.height <= 0) {
    return 0.75;
  }
  const r: number = w.width / w.height;
  if (!Number.isFinite(r) || r <= 0.2 || r >= 5) {
    return 0.75;
  }
  return r;
}

/** URL 规范化：去掉协议无关的 query/hash、统一小写，用于跨接口去重 */
export function normalizeUrl(url: string): string {
  let u: string = url.trim();
  if (u.length === 0) {
    return '';
  }
  const hash: number = u.indexOf('#');
  if (hash >= 0) {
    u = u.substring(0, hash);
  }
  const query: number = u.indexOf('?');
  if (query >= 0) {
    u = u.substring(0, query);
  }
  return u.toLowerCase();
}

/**
 * 一条壁纸的全部去重键：后端 id、本地/目录 id（含 DEDUP_ALIASES 归一）、
 * 规范化后的 imageUrl / thumbUrl。任一命中即视为同一张。
 */
export class WallKeys {
  static of(w: Wallpaper): string[] {
    const out: string[] = [];
    if (w.id.length > 0) {
      out.push(`id:${w.id}`);
      out.push(`rid:${LocalWallpapers.resolveId(w.id)}`);
    }
    if (w.serverId > 0) {
      out.push(`sid:${w.serverId}`);
    }
    const img: string = normalizeUrl(w.imageUrl);
    if (img.length > 0) {
      out.push(`img:${img}`);
    }
    const thumb: string = normalizeUrl(w.thumbUrl);
    if (thumb.length > 0) {
      out.push(`thumb:${thumb}`);
    }
    return out;
  }
}

/** 会话内已出现集合（首页精选/推荐/预览池共用） */
export class HomeSeen {
  private keys: string[] = [];

  has(w: Wallpaper): boolean {
    const ks: string[] = WallKeys.of(w);
    for (let i = 0; i < ks.length; i++) {
      if (this.keys.indexOf(ks[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  add(w: Wallpaper): void {
    const ks: string[] = WallKeys.of(w);
    for (let i = 0; i < ks.length; i++) {
      if (this.keys.indexOf(ks[i]) < 0) {
        this.keys.push(ks[i]);
      }
    }
  }

  addAll(list: Wallpaper[]): void {
    for (let i = 0; i < list.length; i++) {
      this.add(list[i]);
    }
  }

  clear(): void {
    this.keys = [];
  }

  count(): number {
    return this.keys.length;
  }
}

/** 一条推荐卡（wide=true 表示 1 列满宽） */
export class FeedPick {
  wallpaper: Wallpaper = new Wallpaper();
  wide: boolean = false;
  /** LazyForEach 唯一 key（跨轮次单调序列；不能用 wallpaper.id，跨轮会重复） */
  key: string = '';
}

/**
 * 推荐卡 UI key 规则（可单测）
 *
 * 跨轮换 seed 后会合法地再次出现同一 wallpaper.id，因此 key 必须来自
 * 会话内单调递增的 feedSerial，而不是 wallpaper.id / 裸下标。
 * 条目被移除（如日报冲突）时 key 随对象保留，不受数组重排影响。
 */
export class FeedKeyRule {
  static readonly PREFIX: string = 'feed_';

  static make(serial: number): string {
    return `${FeedKeyRule.PREFIX}${serial}`;
  }
}

/** 跨批状态：自上一张满宽以来累计的普通卡数（用于「每 8 张 ≤1 张满宽」） */
export class FeedState {
  normalsSinceWide: number = 0;
}

/**
 * 推荐批量组装规则
 *
 * - 每批基础 20 张；含 1 张满宽时补 1 张普通卡 = 21 张 / 22 格（0 或 2 张不补）；
 * - 满宽条件：横图 + 距上一张满宽已过 ≥8 张普通卡 + 当前普通段为偶数（保证
 *   WaterFlow 分段时每段末行不留单卡空洞）；
 * - **横图（aspect ≥ 1.3）要么以 wide=true 占 2 格，要么本轮直接跳过**，
 *   绝不允许降级成普通窄卡（否则会被 3:4 裁切，横图内容丢失）；
 * - 竖图永不强拉满宽；候选不足时允许少于 20 张，不用竖图凑满宽。
 */
export class FeedComposer {
  static readonly LIMIT: number = 20;
  static readonly WIDE_GAP: number = 8;

  /** 横图当前是否满足满宽配额（不满足则整条跳过，不做普通卡） */
  static wideAllowed(w: Wallpaper, state: FeedState): boolean {
    return isWideWallpaper(w) &&
      state.normalsSinceWide >= FeedComposer.WIDE_GAP &&
      (state.normalsSinceWide % 2) === 0;
  }

  static compose(candidates: Wallpaper[], seen: HomeSeen, excluded: HomeSeen,
    state: FeedState, limit: number = FeedComposer.LIMIT): FeedPick[] {
    const picks: FeedPick[] = [];
    let wideCount: number = 0;
    for (let i = 0; i < candidates.length && picks.length < limit; i++) {
      const w: Wallpaper = candidates[i];
      if (seen.has(w) || excluded.has(w)) {
        continue;
      }
      const wide: boolean = FeedComposer.wideAllowed(w, state);
      if (isWideWallpaper(w) && !wide) {
        // 横图配额未到：本轮跳过，绝不当普通竖卡渲染（避免 3:4 裁切）
        continue;
      }
      const p = new FeedPick();
      p.wallpaper = w;
      p.wide = wide;
      picks.push(p);
      seen.add(w);
      if (wide) {
        wideCount++;
        state.normalsSinceWide = 0;
      } else {
        state.normalsSinceWide++;
      }
    }
    // 总格数（普通卡 1 格 + 满宽 2 格）为奇数时补 1 张普通卡
    if (((picks.length + wideCount) % 2) !== 0) {
      for (let i = 0; i < candidates.length; i++) {
        const w: Wallpaper = candidates[i];
        if (seen.has(w) || excluded.has(w) || isWideWallpaper(w)) {
          continue;
        }
        const p = new FeedPick();
        p.wallpaper = w;
        p.wide = false;
        picks.push(p);
        seen.add(w);
        state.normalsSinceWide++;
        break;
      }
    }
    return picks;
  }
}

/** 精选计划（16 张全部参与轮换） */
export class FeaturedPlan {
  items: Wallpaper[] = [];
  rotationIds: string[] = [];
}

/**
 * 推荐骨架规则（可单测）
 *
 * 3 个灰块必须同处一个全宽 FlowItem（内部三列等宽），
 * 这样 2 列瀑布流下也不会在末行留下第 4 个黑空格。
 */
export class SkeletonRule {
  static readonly COUNT: number = 3;
  /** 骨架段固定为 1 列（全宽），内部再三等分 */
  static readonly CROSS_COUNT: number = 1;
}

/**
 * 精选 16 张选择器
 *
 * 轮换策略：
 *  - 16 个席位全部参与轮换，按「日期 + 批次号 + id」稳定哈希排序；
 *  - 「换一批」时优先排除上一批的 16 张，保证整屏图位全部更换；
 *  - 全部来自本地目录，离线也保证正好 16 张，且不依赖推荐接口。
 */
export class FeaturedSelector {
  /** 32 位稳定哈希（不依赖平台随机数） */
  static hash(s: string): number {
    let h: number = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h = h ^ s.charCodeAt(i);
      h = h * 16777619;
      h = h >>> 0;
    }
    return h;
  }

  /**
   * @param all 本地目录（至少 16 张有效素材）
   * @param dateKey 今日日期（如 2026-11-07）
   * @param previousIds 昨日（或上一批）轮换 ID，优先避开
   * @param batchNo 当日「换一批」次数
   * @param excluded 首页已出现（日报/推荐）的集合
   */
  static select(all: Wallpaper[], dateKey: string, previousIds: string[],
    batchNo: number, excluded: HomeSeen | null): FeaturedPlan {
    const plan = new FeaturedPlan();
    const candidates: Wallpaper[] = [];
    const prevRids: string[] = [];
    for (let i = 0; i < previousIds.length; i++) {
      prevRids.push(LocalWallpapers.resolveId(previousIds[i]));
    }
    for (let i = 0; i < all.length; i++) {
      const w: Wallpaper = all[i];
      if (w.id.startsWith('my_')) {
        // 个人照片没有随包缩略图，不进入精选
        continue;
      }
      if (excluded !== null && excluded.has(w)) {
        continue;
      }
      candidates.push(w);
    }
    candidates.sort((a: Wallpaper, b: Wallpaper): number => {
      const ha: number = FeaturedSelector.hash(`${dateKey}#${batchNo}#${LocalWallpapers.resolveId(a.id)}`);
      const hb: number = FeaturedSelector.hash(`${dateKey}#${batchNo}#${LocalWallpapers.resolveId(b.id)}`);
      if (ha === hb) {
        return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
      }
      return ha - hb;
    });

    const rotation: Wallpaper[] = [];
    const pickedRids: string[] = [];
    // 第一轮：避开上一批 16 张；不足再退回全部候选（保证仍凑满 16）
    for (let pass = 0; pass < 2 && rotation.length < 16; pass++) {
      for (let i = 0; i < candidates.length && rotation.length < 16; i++) {
        const w: Wallpaper = candidates[i];
        const rid: string = LocalWallpapers.resolveId(w.id);
        if (pass === 0 && prevRids.indexOf(rid) >= 0) {
          continue;
        }
        if (pickedRids.indexOf(rid) >= 0) {
          continue;
        }
        pickedRids.push(rid);
        rotation.push(w);
      }
    }
    for (let i = 0; i < rotation.length; i++) {
      plan.items.push(rotation[i]);
      plan.rotationIds.push(rotation[i].id);
    }
    return plan;
  }
}
