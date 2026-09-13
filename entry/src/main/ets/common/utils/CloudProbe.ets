import { cloudDatabase } from '@kit.CloudFoundationKit';
import { BusinessError } from '@ohos.base';

/**
 * 最小探针实体：只声明 id 一个字段
 *
 * 用途：`1008230002 schema parse fail or objectTypeName error` 有两种成因，
 * 用这个"最简表"探一次就能分开：
 *  - 探针也失败 → 对象类型名/存储区不对（`wallpapers` 没建在 `zeroone` 下，或名字大小写不一致）；
 *  - 探针成功、正式实体失败 → 名字没问题，是 `Wallpaper` 里的个别字段与云端 schema 对不上
 *    （最常见是少了 ratingSum / ratingCount，或 uploadTime 不是 Long）。
 */
export class ProbeWallpaper extends cloudDatabase.DatabaseObject {
  id: string = '';

  naturalbase_ClassName(): string {
    return 'wallpapers';
  }
}

export class CloudProbe {
  /**
   * 探一次对象类型是否可访问
   * @returns 空串表示成功；否则返回 `code=... message` 形式的失败描述
   */
  static async probe(): Promise<string> {
    try {
      const query: cloudDatabase.DatabaseQuery<ProbeWallpaper> =
        new cloudDatabase.DatabaseQuery(ProbeWallpaper);
      query.limit(1, 0);
      await cloudDatabase.zone('zeroone').query(query);
      return '';
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      return `code=${err.code} ${err.message === undefined ? '' : err.message}`;
    }
  }
}
