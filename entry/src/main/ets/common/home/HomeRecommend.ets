import { Wallpaper } from '../../model/Wallpaper';
import { WallpaperApi, WallpaperPage } from '../net/WallpaperApi';
import { RecommendCursor, CursorRules, SeededOrder } from './HomeCursor';

/**
 * HomeRecommend —— 首页推荐流适配层
 *
 * 现状（1.6.1 P0）：后端没有专用推荐接口，兼容源使用
 * `GET /api/v1/wallpapers?page=N&pageSize=40&sort=latest`。
 * 这里把「游标」抽象出来（seed + offset + page + round），未来后端提供
 * cursor/seed/offset 参数时只需替换 fetchBatch 的 query，UI 与去重逻辑不动。
 *
 * 一轮翻完（hasMore=false）后，HomePage 调 nextRoundCursor 换新 seed、从 page1
 * 继续；每页顺序用 SeededOrder 确定性打散，避免原序重播。
 *
 * 重要：CURSOR_SUPPORTED = false 明确表示当前**没有**cursor 接口。
 * 不调用不存在的 /recommend，不伪造成功响应。
 */
export class RecommendBatch {
  items: Wallpaper[] = [];
  hasMore: boolean = false;
  /** 请求是否成功（失败时 items 为空，调用方降级） */
  ok: boolean = false;
  /** 本页原始条数（未去重前） */
  rawCount: number = 0;
  /** 本轮是否已翻完（服务端 hasMore=false） */
  roundComplete: boolean = false;
  cursor: RecommendCursor = new RecommendCursor();
}

/** 推荐源适配器 */
export class HomeRecommendApi {
  /** 每批基础 20 张（满宽补齐后最多 21 张） */
  static readonly BATCH_SIZE: number = 20;
  /** 兼容源一次多取一些，抵消跨批去重损耗 */
  static readonly PAGE_SIZE: number = 40;
  /** 当前后端是否支持 cursor+seed+offset（明确 false，禁止伪造） */
  static readonly CURSOR_SUPPORTED: boolean = false;

  static newCursor(dateKey: string, round: number = 0): RecommendCursor {
    const c = new RecommendCursor();
    c.round = round;
    c.seed = CursorRules.seedOf(round === 0 ? dateKey : `${dateKey}#round#${round}`);
    c.offset = 0;
    c.page = 1;
    return c;
  }

  /** 一轮完整结束后换新 seed，从 page1 重新开始（兼容源最小闭环） */
  static nextRoundCursor(src: RecommendCursor, dateKey: string): RecommendCursor {
    return CursorRules.nextRound(src, dateKey);
  }

  /**
   * 拉取一页兼容数据。失败返回 ok=false（不抛错、不伪造空成功）。
   * 返回前按当前 seed 做确定性打散；未来切换推荐接口时，只改这里对 WallpaperApi 的调用。
   */
  static async fetchBatch(cursor: RecommendCursor): Promise<RecommendBatch> {
    const out = new RecommendBatch();
    try {
      const resp = await WallpaperApi.fetchPage(cursor.page, HomeRecommendApi.PAGE_SIZE, -1, 'latest');
      if (!resp.ok || resp.data === undefined) {
        out.ok = false;
        out.hasMore = false;
        out.roundComplete = false;
        out.cursor = cursor;
        return out;
      }
      const page: WallpaperPage = resp.data;
      out.items = SeededOrder.apply(page.items, cursor.seed, cursor.page);
      out.rawCount = page.items.length;
      out.hasMore = page.hasMore;
      out.roundComplete = !page.hasMore;
      out.ok = true;
      out.cursor = CursorRules.next(cursor, page.items.length);
      return out;
    } catch (e) {
      out.ok = false;
      out.hasMore = false;
      out.roundComplete = false;
      out.cursor = cursor;
      return out;
    }
  }
}
