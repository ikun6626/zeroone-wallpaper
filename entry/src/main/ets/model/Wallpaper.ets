/**
 * Wallpaper —— 壁纸数据模型（云端优先 + 本地兜底）
 *
 * 联网版说明：
 *  - imageUrl / thumbUrl 是管理后台返回的远程地址（https://www.gqscc.cn/uploads/...）。
 *    本地内置壁纸（离线兜底）这两项恒为空串，图片走 LocalWallpapers.getLocalImg/getThumb。
 *  - id 约定（关键：保证收藏记录跨数据源稳定）：
 *    · 云端壁纸若对应某张内置壁纸，沿用本地目录 id（如 12019_sunset_2080072），
 *      只是图片源升级为云端高清版，收藏不失效；
 *    · 后台运营新增、本地没有的壁纸，id 为 `c_<后端数字id>`；
 *    · 纯本地壁纸保持内置目录 id。
 *    后端数字 id 单独放在 serverId，用于下载/点赞上报。
 *  - 收藏状态(isFavorite) 是纯前端概念，不进模型：由页面 favorites 列表 + Preferences 管理。
 */
export class Wallpaper {
  /** 壁纸唯一 ID（云端同源沿用本地 id；云端独有 c_<数字>；纯本地为内置目录 ID） */
  id: string = '';
  /** 壁纸标题 */
  title: string = '';
  /** 核心分类（自然风景/城市建筑/极简风格/动物萌宠/摄影作品，由后台分类表下发） */
  category: string = '';
  /** 主色桶（后台图片分析脚本标注：蓝/青/绿/黄绿/橙黄/红/紫/粉/灰；本地壁纸为空串） */
  dominantColor: string = '';
  /** 作者 */
  author: string = '';
  /** 上传时间戳（毫秒） */
  uploadTime: number = 0;
  /** 标签（逗号分隔，如 "科幻太空,暗色"；可同时打多个标签） */
  tags: string = '';
  /** 远程原图地址（云端壁纸才有；离线兜底为空串） */
  imageUrl: string = '';
  /** 远程缩略图地址（云端壁纸才有；离线兜底为空串） */
  thumbUrl: string = '';
  /** 评分总分（用户评分累加） */
  ratingSum: number = 0;
  /** 评分人数 */
  ratingCount: number = 0;
  /** 后端数字 ID（用于下载/点赞上报；纯本地壁纸为 -1） */
  serverId: number = -1;

  constructor(id: string = '', title: string = '', category: string = '', author: string = '',
    uploadTime: number = 0, tags: string = '') {
    this.id = id;
    this.title = title;
    this.category = category;
    this.author = author;
    this.uploadTime = uploadTime;
    this.tags = tags;
  }

  /** 是否云端壁纸（有远程地址即视为云端） */
  get isCloud(): boolean {
    return this.imageUrl.length > 0 || this.thumbUrl.length > 0;
  }

  /** 后端数字 ID（上报用；云端独有壁纸也可从 c_ 前缀解析） */
  get cloudId(): number {
    if (this.serverId > 0) {
      return this.serverId;
    }
    if (this.id.startsWith('c_')) {
      const n = Number(this.id.substring(2));
      return Number.isFinite(n) ? n : -1;
    }
    return -1;
  }

  /** 标签数组（由 tags 字符串解析，方便 UI 使用） */
  get tagList(): string[] {
    if (this.tags.length === 0) {
      return [];
    }
    return this.tags.split(',');
  }

  /** 平均分（无评分返回 0，保留 1 位小数） */
  get avgRating(): number {
    if (this.ratingCount <= 0) {
      return 0;
    }
    return Math.round((this.ratingSum / this.ratingCount) * 10) / 10;
  }
}
