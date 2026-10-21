import { ApiConfig } from './ApiConfig';
import { HttpClient, ApiResponse } from './HttpClient';

/**
 * 后端 DailyFeatured JSON 结构
 *
 * 后端 /api/v1/daily/featured 返回最新一期；无数据返回 null。
 */
export interface ApiDailyFeatured {
  id: number;
  issueNo: number;
  date: string;
  imageUrl: string;
  title: string;
  subtitle: string;
  wallpaperId: number | null;
  enabled: boolean;
}

/**
 * DailyApi —— 今日精选接口封装
 *
 * 用途：HomePage 顶部徽标"第 X 期 · X月X日更新"。
 * 后台每天人工放一张图即新增一期，App 拉取后立即显示新期号 + 日期。
 *
 * 容错：
 *  - 接口失败 / 无数据：返回 null，调用方降级到本地推算（见 HomePage.issueLabel）
 *  - 字段缺失：防御式读取，不抛错
 */
export class DailyApi {
  /**
   * 拉取最新一期今日精选
   * @returns 成功返回 ApiDailyFeatured；无数据或失败返回 null
   */
  static async fetchLatest(): Promise<ApiDailyFeatured | null> {
    const resp: ApiResponse<ApiDailyFeatured | null> =
      await HttpClient.get<ApiDailyFeatured | null>(ApiConfig.PATH.DAILY_FEATURED);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return null;
    }
    const d: ApiDailyFeatured = resp.data;
    // 防御式：缺关键字段视为无效
    if (typeof d.issueNo !== 'number' || d.issueNo <= 0) {
      return null;
    }
    return d;
  }
}
