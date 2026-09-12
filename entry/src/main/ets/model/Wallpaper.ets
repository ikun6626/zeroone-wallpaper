import { cloudDatabase } from '@kit.CloudFoundationKit';

/**
 * Wallpaper —— 壁纸数据模型（CloudDB 实体类）
 *
 * 对应 AGC 云数据库（Cloud DB）中的对象类型 wallpapers，字段（共 10 个）：
 *   id(String 主键)、title(String)、imageUrl(String)、thumbnailUrl(String)、
 *   category(String)、author(String)、uploadTime(Number)、
 *   tags(String，逗号分隔，如 "科幻太空,暗色")、ratingSum(Number)、ratingCount(Number)
 *
 * 说明：
 *  - 必须继承 cloudDatabase.DatabaseObject（SDK 硬性要求）
 *  - 字段必须与 AGC 控制台创建的对象类型字段完全一致（含新增的 tags/ratingSum/ratingCount）
 *  - 收藏状态(isFavorite)、本地兜底图(localImg) 是纯前端概念，不放进实体类：
 *    收藏由页面 favorites 列表 + Preferences 管理；本地兜底图由 DefaultWallpapers.getLocalImg(id) 提供
 */
export class Wallpaper extends cloudDatabase.DatabaseObject {
  /** 壁纸唯一 ID（主键） */
  id: string = '';
  /** 壁纸标题 */
  title: string = '';
  /** 原图 URL（云存储文件访问地址） */
  imageUrl: string = '';
  /** 缩略图 URL（低分辨率地址；当前列表直接加载原图，该字段暂未在 UI 使用） */
  thumbnailUrl: string = '';
  /** 核心分类（自然风光/城市建筑/极简风格/动物萌宠/二次元插画） */
  category: string = '';
  /** 作者 */
  author: string = '';
  /** 上传时间戳（毫秒） */
  uploadTime: number = 0;
  /** 标签（逗号分隔，如 "科幻太空,暗色"；可同时打多个标签） */
  tags: string = '';
  /** 评分总分（用户评分累加） */
  ratingSum: number = 0;
  /** 评分人数 */
  ratingCount: number = 0;

  constructor(id: string = '', title: string = '', imageUrl: string = '', thumbnailUrl: string = '',
    category: string = '', author: string = '', uploadTime: number = 0, tags: string = '') {
    super();
    this.id = id;
    this.title = title;
    this.imageUrl = imageUrl;
    this.thumbnailUrl = thumbnailUrl;
    this.category = category;
    this.author = author;
    this.uploadTime = uploadTime;
    this.tags = tags;
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

  /**
   * 对象类型名：必须与 AGC 控制台「云数据库」中创建的对象类型名称一致。
   * 若真机运行时上报 Schema 配置错误(1008230002)，把控制台对象类型改名为
   * Wallpaper（与类名一致）并删除此方法的重写即可。
   */
  naturalbase_ClassName(): string {
    return 'wallpapers';
  }
}
