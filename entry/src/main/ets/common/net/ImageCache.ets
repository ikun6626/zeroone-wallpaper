import { image } from '@kit.ImageKit';
import http from '@ohos.net.http';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * ImageCache —— 远程图片三级缓存（内存 LRU → 磁盘 → 网络）
 *
 * 职责：
 *  1. fetchBytes(url)：磁盘有就读磁盘（URI 授权无关、断网可用），否则 HTTPS 下载并落盘；
 *     保存原图/编辑原图也走这里 —— 浏览过的图再次保存零流量；
 *  2. getPixelMap(url)：内存 LRU 命中直接返回；否则取字节解码 PixelMap 入缓存；
 *  3. 并发去重：同一 URL 的并发请求共用一个 Promise，不重复下载。
 *
 * 磁盘位置：cacheDir/remote-img（系统级缓存目录，存储紧张时系统可回收）。
 * 内存策略：缩略图 PixelMap LRU 上限 40 张，淘汰最久未用并 release，
 * 滑回时从磁盘重新解码（毫秒级）。
 */

/** 磁盘 LRU 整理用的文件条目（ArkTS 不允许对象字面量作类型，必须显式 interface） */
interface DiskFileEntry {
  name: string;
  size: number;
  mtime: number;
}

export class ImageCache {
  /** 内存缓存（Map 插入顺序 = LRU 顺序） */
  private static mem: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  /** 内存缓存上限（条目数） */
  private static readonly MEM_MAX: number = 40;
  /** 磁盘缓存目录（绝对路径） */
  private static dir: string = '';
  /** 进行中的网络请求（URL → Promise，并发去重） */
  private static flights: Map<string, Promise<ArrayBuffer>> = new Map<string, Promise<ArrayBuffer>>();
  /** 磁盘缓存大小（字节，懒统计；-1 = 未统计） */
  private static diskSize: number = -1;
  /** 磁盘缓存上限 150MB */
  private static readonly DISK_MAX: number = 150 * 1024 * 1024;

  /** 初始化（Index 入口调用一次，幂等） */
  static init(context: common.UIAbilityContext): void {
    if (ImageCache.dir.length > 0) {
      return;
    }
    ImageCache.dir = `${context.cacheDir}/remote-img`;
    try {
      fileIo.mkdirSync(ImageCache.dir, true);
    } catch (e) {
      // 目录已存在时继续
    }
  }

  // ==================== URL → 磁盘文件名 ====================

  /**
   * URL 确定性哈希（djb2 + FNV-1a 双哈希组合，碰撞概率可忽略）。
   * 不用 MD5：避免引入异步加密依赖，几百张图双 32 位哈希足够。
   */
  private static hashName(url: string): string {
    let djb: number = 5381;
    let fnv: number = 0x811C9DC5;
    for (let i = 0; i < url.length; i++) {
      const c: number = url.charCodeAt(i);
      djb = ((djb << 5) + djb + c) | 0;
      fnv = Math.imul(fnv ^ c, 0x01000193);
    }
    const u: number = djb >>> 0;
    const v: number = fnv >>> 0;
    return `${u.toString(16)}_${v.toString(16)}_${url.length}`;
  }

  private static pathOf(url: string): string {
    return `${ImageCache.dir}/${ImageCache.hashName(url)}.img`;
  }

  // ==================== 字节级：磁盘 → 网络 ====================

  /** 磁盘是否已有缓存文件 */
  private static onDisk(url: string): boolean {
    try {
      return fileIo.accessSync(ImageCache.pathOf(url));
    } catch (e) {
      return false;
    }
  }

  /** 读磁盘缓存文件全部字节 */
  private static readDisk(path: string): ArrayBuffer {
    const stat = fileIo.statSync(path);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      return buf;
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 网络下载（http，返回原始字节；非 2xx 抛错） */
  private static async download(url: string): Promise<ArrayBuffer> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000,
        usingCache: false
      };
      const res: http.HttpResponse = await req.request(url, options);
      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`HTTP ${res.responseCode}`);
      }
      return res.result as ArrayBuffer;
    } finally {
      req.destroy();
    }
  }

  /** 字节落盘（先写临时文件再改名，避免下载中断留下半截文件被误读） */
  private static writeDisk(path: string, bytes: ArrayBuffer): void {
    const tmp: string = `${path}.tmp`;
    const file = fileIo.openSync(tmp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, bytes);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(tmp, path);
    if (ImageCache.diskSize >= 0) {
      ImageCache.diskSize += bytes.byteLength;
    }
  }

  /**
   * 获取图片字节：磁盘 → 网络（成功后落盘）。
   * 并发同 URL 共用一个 Promise。
   */
  static async fetchBytes(url: string): Promise<ArrayBuffer> {
    if (url.length === 0) {
      throw new Error('empty url');
    }
    const path: string = ImageCache.pathOf(url);
    if (ImageCache.onDisk(url)) {
      return ImageCache.readDisk(path);
    }
    const flying: Promise<ArrayBuffer> | undefined = ImageCache.flights.get(url);
    if (flying !== undefined) {
      return flying;
    }
    const task: Promise<ArrayBuffer> = (async (): Promise<ArrayBuffer> => {
      try {
        const bytes: ArrayBuffer = await ImageCache.download(url);
        try {
          ImageCache.writeDisk(path, bytes);
          ImageCache.trimDisk();
        } catch (e) {
          // 落盘失败不影响本次使用
        }
        return bytes;
      } finally {
        ImageCache.flights.delete(url);
      }
    })();
    ImageCache.flights.set(url, task);
    return task;
  }

  // ==================== PixelMap 级：内存 LRU ====================

  /**
   * 获取 PixelMap：内存 LRU → fetchBytes 解码。
   * 返回的 PixelMap 所有权属于缓存，调用方不要 release。
   */
  static async getPixelMap(url: string): Promise<image.PixelMap> {
    const hit: image.PixelMap | undefined = ImageCache.mem.get(url);
    if (hit !== undefined) {
      // 提到最前（LRU）
      ImageCache.mem.delete(url);
      ImageCache.mem.set(url, hit);
      return hit;
    }
    const bytes: ArrayBuffer = await ImageCache.fetchBytes(url);
    const src: image.ImageSource = image.createImageSource(bytes);
    let pm: image.PixelMap;
    try {
      pm = await src.createPixelMap();
    } finally {
      try {
        src.release();
      } catch (e) {
        // 忽略释放异常
      }
    }
    ImageCache.mem.set(url, pm);
    ImageCache.evict();
    return pm;
  }

  /** 内存 LRU 淘汰：超上限时释放最早条目 */
  private static evict(): void {
    while (ImageCache.mem.size > ImageCache.MEM_MAX) {
      const oldestKey: string | undefined = ImageCache.mem.keys().next().value;
      if (oldestKey === undefined) {
        break;
      }
      const old: image.PixelMap | undefined = ImageCache.mem.get(oldestKey);
      ImageCache.mem.delete(oldestKey);
      if (old !== undefined) {
        try {
          old.release();
        } catch (e) {
          // 忽略：可能仍被组件持有
        }
      }
    }
  }

  // ==================== 磁盘容量整理 ====================

  /** 磁盘缓存超上限时，按最旧访问时间删除（简单 LRU） */
  private static trimDisk(): void {
    if (ImageCache.dir.length === 0) {
      return;
    }
    try {
      let names: string[] = fileIo.listFileSync(ImageCache.dir);
      let total: number = 0;
      const files: DiskFileEntry[] = [];
      for (const n of names) {
        if (!n.endsWith('.img')) {
          continue;
        }
        const p: string = `${ImageCache.dir}/${n}`;
        const st = fileIo.statSync(p);
        total += st.size;
        // Stat.mtime = 毫秒时间戳（该 SDK 的 Stat 无 mtimeMs）
        const entry: DiskFileEntry = { name: n, size: st.size, mtime: st.mtime };
        files.push(entry);
      }
      ImageCache.diskSize = total;
      if (total <= ImageCache.DISK_MAX) {
        return;
      }
      files.sort((a, b): number => a.mtime - b.mtime);
      for (const f of files) {
        if (total <= ImageCache.DISK_MAX) {
          break;
        }
        try {
          fileIo.unlinkSync(`${ImageCache.dir}/${f.name}`);
          total -= f.size;
        } catch (e) {
          // 删除失败跳过
        }
      }
      ImageCache.diskSize = total;
    } catch (e) {
      // 整理失败不影响主流程
    }
  }

  /** 清空全部缓存（"清除缓存"入口调用） */
  static clearAll(): void {
    ImageCache.mem.forEach((pm: image.PixelMap): void => {
      try {
        pm.release();
      } catch (e) {
        // 忽略
      }
    });
    ImageCache.mem.clear();
    if (ImageCache.dir.length === 0) {
      return;
    }
    try {
      const names: string[] = fileIo.listFileSync(ImageCache.dir);
      for (const n of names) {
        if (n.endsWith('.img')) {
          try {
            fileIo.unlinkSync(`${ImageCache.dir}/${n}`);
          } catch (e) {
            // 忽略
          }
        }
      }
      ImageCache.diskSize = 0;
    } catch (e) {
      // 忽略
    }
  }
}
