import { cloudDatabase } from '@kit.CloudFoundationKit';
import { Wallpaper } from '../../model/Wallpaper';
import { DefaultWallpapers } from '../constants/DefaultWallpapers';

/**
 * CloudDBUtil —— 云数据库工具（Cloud Foundation Kit 云数据库）
 *
 * SDK（API 24）自带 Cloud Foundation Kit，无需安装任何第三方包：
 *   cloudDatabase.zone(区域名)                        → DatabaseZone
 *   new cloudDatabase.DatabaseQuery(实体类)           → 构造查询
 *   zone.query(query) / zone.upsert(objects)          → 查询 / 写入
 *
 * 前置条件：
 *  1. agconnect-services.json 已放入 entry/src/main/resources/rawfile/
 *  2. AGC 控制台已开通云数据库，并创建区域 + 对象类型（见 DELIVERY.md）
 */
export class CloudDBUtil {
  /** 区域名：与 AGC 控制台「云数据库」中创建的存储区域(zone)名称一致 */
  private static readonly ZONE_NAME: string = 'zeroone';

  private static getZone(): cloudDatabase.DatabaseZone {
    return cloudDatabase.zone(CloudDBUtil.ZONE_NAME);
  }

  /**
   * 查询全部壁纸（按上传时间倒序，新的在前）
   */
  static async getAllWallpapers(): Promise<Wallpaper[]> {
    const query: cloudDatabase.DatabaseQuery<Wallpaper> = new cloudDatabase.DatabaseQuery(Wallpaper);
    query.orderByDesc('uploadTime');
    return await CloudDBUtil.getZone().query(query);
  }

  /**
   * 分页查询壁纸（按上传时间倒序）
   * @param limit  每页条数
   * @param offset 跳过条数（已加载条数）
   */
  static async queryWallpaperPage(limit: number, offset: number): Promise<Wallpaper[]> {
    const query: cloudDatabase.DatabaseQuery<Wallpaper> = new cloudDatabase.DatabaseQuery(Wallpaper);
    query.orderByDesc('uploadTime').limit(limit, offset);
    return await CloudDBUtil.getZone().query(query);
  }

  /**
   * 按分类查询壁纸（category 字段精确匹配）
   * @param category 分类名（如 '自然风光'）；传 '全部' 时等价于查询全部
   */
  static async getByCategory(category: string): Promise<Wallpaper[]> {
    if (category === '全部') {
      return CloudDBUtil.getAllWallpapers();
    }
    const query: cloudDatabase.DatabaseQuery<Wallpaper> = new cloudDatabase.DatabaseQuery(Wallpaper);
    query.equalTo('category', category).orderByDesc('uploadTime');
    return await CloudDBUtil.getZone().query(query);
  }

  /**
   * 插入单条壁纸记录（同 id 重复写入 = upsert 覆盖语义）
   * @param wallpaper 壁纸实体（id 客户端生成）
   */
  static async insertOne(wallpaper: Wallpaper): Promise<void> {
    await CloudDBUtil.getZone().upsert(wallpaper);
  }

  /**
   * 批量插入壁纸记录（SDK 原生支持对象数组）
   * @param list 壁纸列表
   */
  static async batchInsert(list: Wallpaper[]): Promise<void> {
    await CloudDBUtil.getZone().upsert(list);
  }

  /**
   * 冷启动数据同步策略（本地秒开 + 后台同步）：
   *  1. 查云数据库全部壁纸；
   *  2. 表为空 → 自动把 10 张内置默认壁纸批量写入云端，并返回默认壁纸；
   *  3. 表有数据 → 返回云端壁纸列表；
   *  4. 查询失败（无网/未配置云服务）→ 返回本地默认壁纸兜底，不抛错。
   */
  static async syncDefaultsIfEmpty(): Promise<Wallpaper[]> {
    try {
      const list: Wallpaper[] = await CloudDBUtil.getAllWallpapers();
      if (list.length === 0) {
        await CloudDBUtil.batchInsert(DefaultWallpapers.ALL);
        console.info('CloudDB: wallpapers object type was empty, defaults written to cloud.');
        return DefaultWallpapers.ALL;
      }
      return list;
    } catch (e) {
      console.error(`CloudDB sync failed, fallback to defaults: ${JSON.stringify(e)}`);
      return DefaultWallpapers.ALL;
    }
  }
}
