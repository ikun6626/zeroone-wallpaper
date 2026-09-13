import { cloudStorage } from '@kit.CloudFoundationKit';

/**
 * CloudStorageUtil —— 云存储取图（AGC 云存储）
 *
 * 背景（已对本机 SDK 的 cloudStorage.d.ts 逐条核对）：
 *  SDK 只提供 `bucket / uploadFile / downloadFile / getDownloadURL / deleteFile / list / getMetadata / setMetadata`，
 *  **没有设置公共读或获取桶域名的接口**；控制台那边给的是"共享令牌"，且上限 50 个，
 *  覆盖不了上百个文件。所以正确用法是：对象保持私有，需要显示时用 `getDownloadURL()` 换临时链接。
 *
 * 约定：记录里存**云存储路径**（如 `thumbs/xxx_thumb.jpg`）或**完整 https 链接**。
 *  - 完整链接（内置图、自建 CDN）：原样返回；
 *  - 路径：交给 SDK 换临时链接，并按 path 在内存里缓存，避免同一张图反复签发。
 *
 * 为什么不落盘缓存链接：临时链接有有效期，写进本地缓存或云数据库都会过期；
 * 落盘只存路径，链接每次进程启动重新签发（有缓存兜底，开销很小）。
 */

/** 链接缓存项 */
interface UrlCacheEntry {
  url: string;
  at: number;
}

export class CloudStorageUtil {
  /** path → 临时链接（进程内缓存） */
  private static cache: Map<string, UrlCacheEntry> = new Map<string, UrlCacheEntry>();
  /**
   * 缓存有效期：AGC 临时链接本身有有效期，这里保守按 30 分钟刷新一次，
   * 既不浪费签发请求，也不会拿一个快过期的链接去加载。
   */
  private static readonly TTL_MS: number = 30 * 60 * 1000;

  /** 是否已经是可直接给 Image 用的完整链接 */
  static isDirectUrl(value: string): boolean {
    return value.startsWith('http://') || value.startsWith('https://');
  }

  /**
   * 路径或链接 → 可直接加载的链接
   * 失败时返回上一次成功的链接（若有），否则返回空串，由界面走占位/兜底逻辑
   */
  static async urlFor(pathOrUrl: string): Promise<string> {
    const value: string = pathOrUrl.trim();
    if (value.length === 0 || CloudStorageUtil.isDirectUrl(value)) {
      return value;
    }
    const now: number = Date.now();
    const hit: UrlCacheEntry | undefined = CloudStorageUtil.cache.get(value);
    if (hit !== undefined && now - hit.at < CloudStorageUtil.TTL_MS) {
      return hit.url;
    }
    try {
      const url: string = await cloudStorage.bucket().getDownloadURL(value);
      const entry: UrlCacheEntry = { url: url, at: now };
      CloudStorageUtil.cache.set(value, entry);
      return url;
    } catch (e) {
      console.error(`CloudStorageUtil getDownloadURL failed for ${value}: ${JSON.stringify(e)}`);
      // 已过期但有旧链接时先顶上，避免网络抖动导致整屏空白
      return hit !== undefined ? hit.url : '';
    }
  }

  /** 清空缓存（切换账号/退出登录一类场景使用；当前应用无账号体系，备用） */
  static clearCache(): void {
    CloudStorageUtil.cache.clear();
  }
}
