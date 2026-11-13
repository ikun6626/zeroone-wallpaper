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
 *  2. getPixelMap(url, w, h)：内存 LRU 命中直接返回；否则取字节解码 PixelMap 入缓存。
 *     传了目标尺寸就按目标尺寸降采样解码（卡片），不传则解码原图（预览/保存）；
 *  3. 并发去重：同一 URL 的并发请求共用一个 Promise，不重复下载。
 *
 * 性能约束（首页滑动 AppFreeze 修复，1.6.2）：
 *  - 所有 fileIo 走 Promise 版，绝不在 UI/JS 线程做同步磁盘 IO；
 *  - 磁盘容量整理（trimDisk）不在下载热路径上跑，改为写入次数累计 + 空闲延迟触发；
 *  - 解码并发 2、IO 并发 3，避免一屏 20 张同时解码把主线程/内存打满；
 *  - 内存缓存按字节预算淘汰（卡片 64MB / 原图 40MB），key 带尺寸档，
 *    避免原图请求把卡片缓存冲掉，也避免同一张图不同尺寸互相覆盖。
 */

/** 磁盘 LRU 整理用的文件条目（ArkTS 不允许对象字面量作类型，必须显式 interface） */
interface DiskFileEntry {
  name: string;
  size: number;
  mtime: number;
}

/** 内存缓存条目：PixelMap + 估算字节数（宽×高×4） */
interface MemEntry {
  pm: image.PixelMap;
  bytes: number;
}

/**
 * 简单并发闸门：超过 limit 的请求排队，先到先执行。
 * ArkTS 没有信号量原语，这里用队列 + 计数实现，release 时唤醒队首。
 */
class Gate {
  private limit: number;
  private running: number = 0;
  private queue: Array<() => void> = [];

  constructor(limit: number) {
    this.limit = limit;
  }

  async acquire(): Promise<void> {
    if (this.running < this.limit) {
      this.running++;
      return;
    }
    await new Promise<void>((resolve): void => {
      this.queue.push((): void => {
        resolve();
      });
    });
    this.running++;
  }

  release(): void {
    this.running--;
    const next: (() => void) | undefined = this.queue.shift();
    if (next !== undefined) {
      next();
    }
  }
}

export class ImageCache {
  /** 卡片/列表内存缓存（Map 插入顺序 = LRU 顺序） */
  private static mem: Map<string, MemEntry> = new Map<string, MemEntry>();
  /** 原图内存缓存（预览/编辑，独立预算，避免冲掉卡片缓存） */
  private static memFull: Map<string, MemEntry> = new Map<string, MemEntry>();
  /** 卡片缓存字节数上限 64MB（按尺寸档存的是降采样图，单张约 1~2MB） */
  private static readonly MEM_BUDGET: number = 64 * 1024 * 1024;
  /** 卡片缓存条数上限（兜底，防止极小图占满 Map） */
  private static readonly MEM_MAX: number = 60;
  /** 原图缓存字节数上限 40MB（2~3 张 1080×2340） */
  private static readonly MEM_FULL_BUDGET: number = 40 * 1024 * 1024;
  /** 原图缓存条数上限 2 张（预览只同时看一张，切图时保留上一张便于回退） */
  private static readonly MEM_FULL_MAX: number = 2;
  /** 当前卡片缓存字节数 */
  private static memBytes: number = 0;
  /** 当前原图缓存字节数 */
  private static memFullBytes: number = 0;
  /** 磁盘缓存目录（绝对路径） */
  private static dir: string = '';
  /** 进行中的网络请求（URL → Promise，并发去重） */
  private static flights: Map<string, Promise<ArrayBuffer>> = new Map<string, Promise<ArrayBuffer>>();
  /** 磁盘缓存大小（字节，懒统计；-1 = 未统计） */
  private static diskSize: number = -1;
  /** 磁盘缓存上限 150MB */
  private static readonly DISK_MAX: number = 150 * 1024 * 1024;
  /** 解码并发（createPixelMap 会分配大块内存，2 个足够跑满且不炸峰值） */
  private static readonly decodeGate: Gate = new Gate(2);
  /** IO 并发（磁盘读 + 网络下载，避免一屏同时读 20 个 2MB 文件） */
  private static readonly ioGate: Gate = new Gate(3);
  /** 写入累计次数（每 N 次触发一次磁盘整理） */
  private static writesSinceTrim: number = 0;
  /** 磁盘整理触发阈值：20 次写入 */
  private static readonly TRIM_EVERY_WRITES: number = 20;
  /** 已有一次整理在排队（避免重复定时器） */
  private static trimScheduled: boolean = false;

  /** 初始化（Index 入口调用一次，幂等） */
  static init(context: common.UIAbilityContext): void {
    if (ImageCache.dir.length > 0) {
      return;
    }
    ImageCache.dir = `${context.cacheDir}/remote-img`;
    // 启动时只建目录（一次、非热路径）；换成异步会让首屏读写抢跑，保留同步更稳
    try {
      fileIo.mkdirSync(ImageCache.dir, true);
    } catch (e) {
      // 目录已存在时继续
    }
    // 空闲时做一次磁盘容量整理（历史缓存可能已经超限）
    ImageCache.scheduleTrim(5000);
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

  /** 磁盘是否已有缓存文件（异步，不再阻塞 JS 线程） */
  private static async onDisk(path: string): Promise<boolean> {
    try {
      return await fileIo.access(path);
    } catch (e) {
      return false;
    }
  }

  /** 读磁盘缓存文件全部字节（异步 read，不阻塞 UI） */
  private static async readDisk(path: string): Promise<ArrayBuffer> {
    const stat = await fileIo.stat(path);
    if (stat.size <= 0) {
      return new ArrayBuffer(0);
    }
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      await fileIo.read(file.fd, buf);
      return buf;
    } finally {
      try {
        await fileIo.close(file);
      } catch (e) {
        // 关闭失败忽略
      }
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
  private static async writeDisk(path: string, bytes: ArrayBuffer): Promise<void> {
    const tmp: string = `${path}.tmp`;
    const file = await fileIo.open(tmp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    try {
      await fileIo.write(file.fd, bytes);
    } finally {
      try {
        await fileIo.close(file);
      } catch (e) {
        // 关闭失败忽略
      }
    }
    await fileIo.rename(tmp, path);
    if (ImageCache.diskSize >= 0) {
      ImageCache.diskSize += bytes.byteLength;
    }
    ImageCache.writesSinceTrim++;
    if (ImageCache.writesSinceTrim >= ImageCache.TRIM_EVERY_WRITES
      || ImageCache.diskSize < 0
      || ImageCache.diskSize > ImageCache.DISK_MAX) {
      ImageCache.writesSinceTrim = 0;
      // 不在下载热路径上跑整理：延后到空闲
      ImageCache.scheduleTrim(2000);
    }
  }

  /** 安排一次延迟磁盘整理（合并多次触发，避免重复遍历目录） */
  private static scheduleTrim(delayMs: number): void {
    if (ImageCache.trimScheduled) {
      return;
    }
    ImageCache.trimScheduled = true;
    setTimeout((): void => {
      ImageCache.trimScheduled = false;
      ImageCache.trimDisk().catch((): void => {
        // 整理失败不影响主流程
      });
    }, delayMs);
  }

  /**
   * 获取图片字节：磁盘 → 网络（成功后落盘）。
   * 并发同 URL 共用一个 Promise；读盘/下载受 IO 闸门限制。
   */
  static async fetchBytes(url: string): Promise<ArrayBuffer> {
    if (url.length === 0) {
      throw new Error('empty url');
    }
    const path: string = ImageCache.pathOf(url);
    await ImageCache.ioGate.acquire();
    try {
      if (await ImageCache.onDisk(path)) {
        try {
          const buf: ArrayBuffer = await ImageCache.readDisk(path);
          if (buf.byteLength > 0) {
            return buf;
          }
          // 0 字节 / 读失败：删掉坏缓存，按未命中走网络
          try {
            await fileIo.unlink(path);
          } catch (e) {
            // 删除失败忽略
          }
        } catch (e) {
          // 读磁盘异常：按未命中处理
        }
      }
    } finally {
      ImageCache.ioGate.release();
    }
    const flying: Promise<ArrayBuffer> | undefined = ImageCache.flights.get(url);
    if (flying !== undefined) {
      return flying;
    }
    const task: Promise<ArrayBuffer> = (async (): Promise<ArrayBuffer> => {
      try {
        const bytes: ArrayBuffer = await ImageCache.download(url);
        try {
          await ImageCache.writeDisk(path, bytes);
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
   * 尺寸档：向上取 64px 的整倍数。
   * 目的是让同一张卡在布局抖动几像素时仍命中同一份缓存，不做无谓重解码。
   */
  private static bucket(px: number): number {
    if (px <= 0) {
      return 0;
    }
    return Math.max(64, Math.ceil(px / 64) * 64);
  }

  /**
   * 获取 PixelMap。
   * @param url 远程地址
   * @param targetW 目标显示宽度（px）；<=0 表示按原图解码（预览、保存）
   * @param targetH 目标显示高度（px）
   * 返回的 PixelMap 所有权属于缓存，调用方不要 release。
   */
  static async getPixelMap(url: string, targetW: number = 0, targetH: number = 0): Promise<image.PixelMap> {
    const full: boolean = targetW <= 0 || targetH <= 0;
    const wantW: number = full ? 0 : ImageCache.bucket(targetW);
    const wantH: number = full ? 0 : ImageCache.bucket(targetH);
    const key: string = full ? `orig|${url}` : `${wantW}x${wantH}|${url}`;
    const store: Map<string, MemEntry> = full ? ImageCache.memFull : ImageCache.mem;
    const hit: MemEntry | undefined = store.get(key);
    if (hit !== undefined) {
      // 提到最前（LRU）
      store.delete(key);
      store.set(key, hit);
      return hit.pm;
    }
    const bytes: ArrayBuffer = await ImageCache.fetchBytes(url);
    await ImageCache.decodeGate.acquire();
    let pm: image.PixelMap;
    try {
      pm = await ImageCache.decode(bytes, wantW, wantH);
    } finally {
      ImageCache.decodeGate.release();
    }
    ImageCache.put(key, pm, full);
    return pm;
  }

  /** 解码：wantW/wantH 为 0 时解原图；否则保比例缩到能覆盖目标框的最小尺寸 */
  private static async decode(bytes: ArrayBuffer, wantW: number, wantH: number): Promise<image.PixelMap> {
    const src: image.ImageSource = image.createImageSource(bytes);
    try {
      if (wantW <= 0 || wantH <= 0) {
        return await src.createPixelMap();
      }
      const info: image.ImageInfo = await src.getImageInfo();
      const sw: number = info.size.width;
      const sh: number = info.size.height;
      if (sw <= 0 || sh <= 0) {
        return await src.createPixelMap();
      }
      // 覆盖式缩放：短边也够用（Cover 裁切后仍清晰），且绝不放大原图
      const scale: number = Math.min(1, Math.max(wantW / sw, wantH / sh));
      const dw: number = Math.max(1, Math.round(sw * scale));
      const dh: number = Math.max(1, Math.round(sh * scale));
      if (dw >= sw && dh >= sh) {
        return await src.createPixelMap();
      }
      const desired: image.Size = { width: dw, height: dh };
      const opts: image.DecodingOptions = { desiredSize: desired };
      return await src.createPixelMap(opts);
    } finally {
      try {
        src.release();
      } catch (e) {
        // 忽略释放异常
      }
    }
  }

  /** 写入内存缓存并按字节预算淘汰 */
  private static put(key: string, pm: image.PixelMap, full: boolean): void {
    const store: Map<string, MemEntry> = full ? ImageCache.memFull : ImageCache.mem;
    const info: image.ImageInfo = pm.getImageInfoSync();
    const bytes: number = info.size.width * info.size.height * 4;
    const old: MemEntry | undefined = store.get(key);
    if (old !== undefined) {
      store.delete(key);
      if (full) {
        ImageCache.memFullBytes -= old.bytes;
      } else {
        ImageCache.memBytes -= old.bytes;
      }
    }
    const entry: MemEntry = { pm: pm, bytes: bytes };
    store.set(key, entry);
    if (full) {
      ImageCache.memFullBytes += bytes;
    } else {
      ImageCache.memBytes += bytes;
    }
    ImageCache.evict(full);
  }

  /** 内存淘汰：先按字节预算，再按条数兜底，释放最早条目 */
  private static evict(full: boolean): void {
    const store: Map<string, MemEntry> = full ? ImageCache.memFull : ImageCache.mem;
    const maxEntries: number = full ? ImageCache.MEM_FULL_MAX : ImageCache.MEM_MAX;
    const maxBytes: number = full ? ImageCache.MEM_FULL_BUDGET : ImageCache.MEM_BUDGET;
    while (store.size > 1) {
      const bytes: number = full ? ImageCache.memFullBytes : ImageCache.memBytes;
      if (store.size <= maxEntries && bytes <= maxBytes) {
        break;
      }
      const oldestKey: string | undefined = store.keys().next().value;
      if (oldestKey === undefined) {
        break;
      }
      const old: MemEntry | undefined = store.get(oldestKey);
      store.delete(oldestKey);
      if (old !== undefined) {
        if (full) {
          ImageCache.memFullBytes -= old.bytes;
        } else {
          ImageCache.memBytes -= old.bytes;
        }
        try {
          old.pm.release();
        } catch (e) {
          // 忽略：可能仍被组件持有
        }
      }
    }
  }

  // ==================== 磁盘容量整理 ====================

  /** 磁盘缓存超上限时，按最旧访问时间删除（简单 LRU；异步、只在空闲跑） */
  private static async trimDisk(): Promise<void> {
    if (ImageCache.dir.length === 0) {
      return;
    }
    try {
      const names: string[] = await fileIo.listFile(ImageCache.dir);
      let total: number = 0;
      const files: DiskFileEntry[] = [];
      for (const n of names) {
        if (!n.endsWith('.img')) {
          continue;
        }
        const p: string = `${ImageCache.dir}/${n}`;
        const st = await fileIo.stat(p);
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
          await fileIo.unlink(`${ImageCache.dir}/${f.name}`);
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
    ImageCache.mem.forEach((entry: MemEntry): void => {
      try {
        entry.pm.release();
      } catch (e) {
        // 忽略
      }
    });
    ImageCache.mem.clear();
    ImageCache.memBytes = 0;
    ImageCache.memFull.forEach((entry: MemEntry): void => {
      try {
        entry.pm.release();
      } catch (e) {
        // 忽略
      }
    });
    ImageCache.memFull.clear();
    ImageCache.memFullBytes = 0;
    if (ImageCache.dir.length === 0) {
      return;
    }
    (async (): Promise<void> => {
      try {
        const names: string[] = await fileIo.listFile(ImageCache.dir);
        for (const n of names) {
          if (n.endsWith('.img')) {
            try {
              await fileIo.unlink(`${ImageCache.dir}/${n}`);
            } catch (e) {
              // 忽略
            }
          }
        }
        ImageCache.diskSize = 0;
      } catch (e) {
        // 忽略
      }
    })();
  }
}
