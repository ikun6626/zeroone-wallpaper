import { Wallpaper } from '../../model/Wallpaper';

/**
 * HomeCursor —— 推荐游标纯规则（不依赖网络，可单测）
 *
 * 当前后端没有 cursor/seed/offset 参数，这里先把字段与推进规则固定下来：
 *  - page 是当前真实生效的兼容分页参数；
 *  - seed/offset 为未来推荐接口预留，本轮用于「一轮结束后换 seed 打散续流」；
 *  - 不伪造请求：页面仍然只请求 page/pageSize。
 */
export class RecommendCursor {
  /** 本轮种子（用于每页稳定打散，轮次隔离基础） */
  seed: number = 0;
  /** 本轮已消费原始条数（未来 cursor 参数） */
  offset: number = 0;
  /** 兼容源页码（当前真实生效） */
  page: number = 1;
  /** 第几轮（0 基；一轮翻完后 +1 换 seed） */
  round: number = 0;
}

export class CursorRules {
  static seedOf(dateKey: string): number {
    let h: number = 0;
    for (let i = 0; i < dateKey.length; i++) {
      h = (h * 31 + dateKey.charCodeAt(i)) >>> 0;
    }
    return h;
  }

  static next(src: RecommendCursor, rawCount: number): RecommendCursor {
    const out = new RecommendCursor();
    out.seed = src.seed;
    out.offset = src.offset + (rawCount > 0 ? rawCount : 0);
    out.page = src.page + 1;
    out.round = src.round;
    return out;
  }

  /** 一轮完整结束：换新 seed、重置 page/offset，从第 1 页继续 */
  static nextRound(src: RecommendCursor, dateKey: string): RecommendCursor {
    const out = new RecommendCursor();
    out.round = src.round + 1;
    out.seed = CursorRules.seedOf(`${dateKey}#round#${out.round}`);
    out.offset = 0;
    out.page = 1;
    return out;
  }
}

/**
 * 每页确定性稳定打散（纯函数）
 *
 * 同一 seed + page 对同一批候选输出完全相同的顺序；换 seed 后顺序变化，
 * 保证兼容源「一轮结束后不会按原顺序重播」。
 */
export class SeededOrder {
  static hash(s: string): number {
    let h: number = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h = h ^ s.charCodeAt(i);
      h = h * 16777619;
      h = h >>> 0;
    }
    return h;
  }

  static apply(list: Wallpaper[], seed: number, page: number): Wallpaper[] {
    const out: Wallpaper[] = list.slice();
    out.sort((a: Wallpaper, b: Wallpaper): number => {
      const ha: number = SeededOrder.hash(`${seed}#${page}#${a.id}`);
      const hb: number = SeededOrder.hash(`${seed}#${page}#${b.id}`);
      if (ha === hb) {
        return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
      }
      return ha - hb;
    });
    return out;
  }
}

