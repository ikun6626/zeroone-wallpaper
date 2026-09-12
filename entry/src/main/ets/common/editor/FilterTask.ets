/**
 * FilterTask —— 滤镜/纹理像素处理（TaskPool 后台线程）
 *
 * 说明：
 *  - 两个入口函数都用 @Concurrent 装饰，可被 taskpool.execute 调度到工作线程执行，
 *    避免逐像素计算（720×1280 ≈ 92 万像素 × 多次采样）阻塞 UI 线程。
 *  - 跨线程只传 ArrayBuffer（可序列化），不传 PixelMap：PixelMap 跨线程后原线程
 *    再调 API 会报错（501/7600106）。
 *  - es2abc 限制：@Concurrent 函数体内只能使用 import 变量或本函数内的局部变量，
 *    因此常量（乐高块大小）与工具函数（钳制/噪点）都声明在函数内部，不能放模块顶层。
 */

/**
 * 滤镜处理（TaskPool 入口）
 * @param bytes RGBA_8888 像素缓冲（会在缓冲上原地修改并返回）
 * @param w     图宽
 * @param h     图高
 * @param name  滤镜名（与 ImageEditor 的 FILTERS 名称一致）
 */
@Concurrent
export function runFilterTask(bytes: ArrayBuffer, w: number, h: number, name: string): ArrayBuffer {
  // ===== 局部常量（@Concurrent 不允许引用模块顶层变量） =====
  const LEGO_BLOCK: number = 16;

  // ===== 局部工具函数 =====
  const clampByte = (v: number): number => Math.min(255, Math.max(0, v));

  const px: Uint8Array = new Uint8Array(bytes);
  // 需要读邻居像素的滤镜统一从原图快照读取，避免行序遍历的原地写入污染邻居
  const orig: Uint8Array = px.slice();
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i: number = (y * w + x) * 4;
      let r: number = px[i];
      let g: number = px[i + 1];
      let b: number = px[i + 2];
      if (name === '黑白') {
        const v: number = 0.299 * r + 0.587 * g + 0.114 * b;
        r = v;
        g = v;
        b = v;
      } else if (name === '复古') {
        r = 0.393 * r + 0.769 * g + 0.189 * b;
        g = 0.349 * r + 0.686 * g + 0.168 * b;
        b = 0.272 * r + 0.534 * g + 0.131 * b;
      } else if (name === '暖色') {
        r = r * 1.18;
        g = g * 1.05;
        b = b * 0.82;
      } else if (name === '冷色') {
        r = r * 0.82;
        g = g * 1.0;
        b = b * 1.18;
      } else if (name === '胶片') {
        r = (r - 128) * 1.18 + 128;
        g = (g - 128) * 1.18 + 128;
        b = (b - 128) * 1.08 + 128;
      } else if (name === '清新') {
        r = r * 0.8 + 40;
        g = g * 0.85 + 35;
        b = b * 0.9 + 30;
      } else if (name === '反转') {
        r = 255 - r;
        g = 255 - g;
        b = 255 - b;
      } else if (name === '鲜艳') {
        const avg: number = (r + g + b) / 3;
        r = avg + (r - avg) * 1.5;
        g = avg + (g - avg) * 1.5;
        b = avg + (b - avg) * 1.5;
      } else if (name === '粉彩') {
        const avg: number = (r + g + b) / 3;
        r = r * 0.55 + avg * 0.45 + 30;
        g = g * 0.55 + avg * 0.45 + 30;
        b = b * 0.55 + avg * 0.45 + 30;
      } else if (name === '暮色') {
        r = r * 1.15 + 12;
        g = g * 1.02 + 4;
        b = b * 0.85 - 6;
      } else if (name === '褪色') {
        const avg: number = (r + g + b) / 3;
        r = r * 0.55 + avg * 0.45 + 20;
        g = g * 0.55 + avg * 0.45 + 20;
        b = b * 0.55 + avg * 0.45 + 20;
      } else if (name === '暗角') {
        const dx: number = (x - w / 2) / (w / 2);
        const dy: number = (y - h / 2) / (h / 2);
        const d: number = Math.sqrt(dx * dx + dy * dy);
        const f: number = 1 - 0.5 * Math.max(0, d - 0.5);
        r = r * f;
        g = g * f;
        b = b * f;
      } else if (name === '水墨') {
        // 灰度
        const v: number = 0.299 * r + 0.587 * g + 0.114 * b;
        // S 曲线压暗中间调（模拟墨色浓淡：亮部更亮、暗部更沉，中间向暗部收）
        const norm: number = v / 255;
        const curved: number = norm < 0.5
          ? 2 * norm * norm                      // 暗部：二次方加深
          : 1 - Math.pow(-2 * norm + 2, 2) / 2;  // 亮部：保持通透
        let ink: number = curved * 255;
        // 边缘墨迹：Sobel 检测轮廓并压暗（模拟毛笔勾边）
        let gx: number = 0;
        let gy: number = 0;
        for (let dy2 = -1; dy2 <= 1; dy2++) {
          for (let dx2 = -1; dx2 <= 1; dx2++) {
            if (dx2 === 0 && dy2 === 0) {
              continue;
            }
            const nx: number = Math.max(0, Math.min(w - 1, x + dx2));
            const ny: number = Math.max(0, Math.min(h - 1, y + dy2));
            const j: number = (ny * w + nx) * 4;
            const ov: number = 0.299 * orig[j] + 0.587 * orig[j + 1] + 0.114 * orig[j + 2];
            gx += ov * dx2;
            gy += ov * dy2;
          }
        }
        const edge: number = Math.sqrt(gx * gx + gy * gy);
        ink = ink - edge * 0.35;  // 轮廓处加深
        // 冷灰偏色（墨色带青）：R 略减，B 略增
        r = ink * 0.96;
        g = ink;
        b = ink * 1.04;
      } else if (name === '油画') {
        const avg: number = (r + g + b) / 3;
        r = avg + (r - avg) * 1.4;
        g = avg + (g - avg) * 1.4;
        b = avg + (b - avg) * 1.4;
        r = Math.floor(r / 36) * 36 + 14;
        g = Math.floor(g / 36) * 36 + 14;
        b = Math.floor(b / 36) * 36 + 14;
        const n: number = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
        const nv: number = n - Math.floor(n);
        r += (nv - 0.5) * 10;
        g += (nv - 0.5) * 10;
        b += (nv - 0.5) * 10;
      } else if (name === '印象派') {
        let rr: number = 0;
        let gg: number = 0;
        let bb: number = 0;
        let cnt: number = 0;
        for (let dy2 = -1; dy2 <= 1; dy2++) {
          for (let dx2 = -1; dx2 <= 1; dx2++) {
            const nx: number = Math.max(0, Math.min(w - 1, x + dx2));
            const ny: number = Math.max(0, Math.min(h - 1, y + dy2));
            const j: number = (ny * w + nx) * 4;
            rr += orig[j];
            gg += orig[j + 1];
            bb += orig[j + 2];
            cnt++;
          }
        }
        r = rr / cnt;
        g = gg / cnt;
        b = bb / cnt;
        const avg: number = (r + g + b) / 3;
        r = avg + (r - avg) * 0.7 + 12;
        g = avg + (g - avg) * 0.7 + 12;
        b = avg + (b - avg) * 0.7 + 12;
      } else if (name === '剪纸') {
        const avg: number = (r + g + b) / 3;
        r = avg + (r - avg) * 1.3;
        g = avg + (g - avg) * 1.3;
        b = avg + (b - avg) * 1.3;
        r = Math.floor(r / 64) * 64 + 32;
        g = Math.floor(g / 64) * 64 + 32;
        b = Math.floor(b / 64) * 64 + 32;
      } else if (name === '乐高') {
        const bx: number = Math.floor(x / LEGO_BLOCK);
        const by: number = Math.floor(y / LEGO_BLOCK);
        const cx: number = Math.min(w - 1, bx * LEGO_BLOCK + Math.floor(LEGO_BLOCK / 2));
        const cy: number = Math.min(h - 1, by * LEGO_BLOCK + Math.floor(LEGO_BLOCK / 2));
        const ci: number = (cy * w + cx) * 4;
        // 块色固定读快照中心，保证同一乐高块内所有像素颜色一致
        r = orig[ci];
        g = orig[ci + 1];
        b = orig[ci + 2];
        const edgeX: number = x % LEGO_BLOCK;
        const edgeY: number = y % LEGO_BLOCK;
        if (edgeX === 0 || edgeY === 0) {
          r *= 0.55;
          g *= 0.55;
          b *= 0.55;
        }
        const dxb: number = (x - bx * LEGO_BLOCK) / LEGO_BLOCK - 0.5;
        const dyb: number = (y - by * LEGO_BLOCK) / LEGO_BLOCK - 0.5;
        const db: number = Math.sqrt(dxb * dxb + dyb * dyb);
        if (db < 0.32) {
          const lift: number = (0.32 - db) * 220;
          r += lift;
          g += lift;
          b += lift;
        }
      } else if (name === '金属') {
        const v: number = 0.299 * r + 0.587 * g + 0.114 * b;
        const xl: number = Math.max(0, x - 1);
        const yl: number = Math.max(0, y - 1);
        const il: number = (y * w + xl) * 4;
        const iu: number = (yl * w + x) * 4;
        // 边缘比较的邻居读快照，避免读到本轮已改像素
        const edge: number = Math.abs(orig[il] - r) + Math.abs(orig[iu] - r);
        r = (v - 128) * 1.5 + 128 + edge * 1.5;
        g = r;
        b = r;
      } else if (name === '毛绒') {
        let rr: number = 0;
        let gg: number = 0;
        let bb: number = 0;
        let cnt: number = 0;
        for (let dy2 = -1; dy2 <= 1; dy2++) {
          for (let dx2 = -1; dx2 <= 1; dx2++) {
            const nx: number = Math.max(0, Math.min(w - 1, x + dx2));
            const ny: number = Math.max(0, Math.min(h - 1, y + dy2));
            const j: number = (ny * w + nx) * 4;
            rr += orig[j];
            gg += orig[j + 1];
            bb += orig[j + 2];
            cnt++;
          }
        }
        r = rr / cnt * 1.08;
        g = gg / cnt * 1.06;
        b = bb / cnt * 1.0;
        const n: number = Math.sin(x * 31.9898 + y * 91.233) * 43758.5453;
        const nv: number = n - Math.floor(n);
        r += (nv - 0.5) * 16;
        g += (nv - 0.5) * 16;
        b += (nv - 0.5) * 16;
      }
      px[i] = clampByte(r);
      px[i + 1] = clampByte(g);
      px[i + 2] = clampByte(b);
    }
  }
  return bytes;
}

/**
 * 纹理叠加处理（TaskPool 入口，在传入缓冲上原地修改）
 * @param bytes     RGBA_8888 像素缓冲
 * @param w         图宽
 * @param h         图高
 * @param name      纹理名：纸纹/水彩纸纹/噪点/光晕/污渍
 * @param strength  强度 0~100
 */
@Concurrent
export function runTextureTask(bytes: ArrayBuffer, w: number, h: number,
  name: string, strength: number): ArrayBuffer {
  // ===== 局部工具函数（@Concurrent 不允许引用模块顶层函数） =====
  const clampByte = (v: number): number => Math.min(255, Math.max(0, v));
  const noise2 = (x: number, y: number): number => {
    const n: number = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return n - Math.floor(n);
  };

  const px: Uint8Array = new Uint8Array(bytes);
  const k: number = strength / 100;

  // 污渍斑点：用 4 个并行数字（x/y/r/a）描述，避免在并发函数内声明对象数组
  const STAIN_COUNT: number = 8;
  const sx: number[] = new Array<number>(STAIN_COUNT);
  const sy: number[] = new Array<number>(STAIN_COUNT);
  const sr: number[] = new Array<number>(STAIN_COUNT);
  const sa: number[] = new Array<number>(STAIN_COUNT);
  if (name === '污渍') {
    for (let i = 0; i < STAIN_COUNT; i++) {
      sx[i] = Math.random() * w;
      sy[i] = Math.random() * h;
      sr[i] = 30 + Math.random() * 90;
      sa[i] = 0.12 + Math.random() * 0.18;
    }
  }

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i: number = (y * w + x) * 4;
      const r: number = px[i];
      const g: number = px[i + 1];
      const b: number = px[i + 2];
      let nr: number = r;
      let ng: number = g;
      let nb: number = b;
      if (name === '纸纹') {
        const t: number = 0.90 + noise2(x, y) * 0.10;
        nr = r * t + 5;
        ng = g * t + 4;
        nb = b * t + 2;
      } else if (name === '水彩纸纹') {
        const coarseX: number = Math.floor(x / 3);
        const coarseY: number = Math.floor(y / 3);
        const t: number = 0.86 + noise2(coarseX, coarseY) * 0.14;
        nr = r * t;
        ng = g * t;
        nb = b * t;
      } else if (name === '噪点') {
        // 噪点幅度从 ±7% 提到 ±20%，颗粒感明显可见
        const t: number = 0.80 + noise2(x, y) * 0.40;
        nr = r * t;
        ng = g * t;
        nb = b * t;
      } else if (name === '光晕') {
        const dx: number = (x - w / 2) / (w / 2);
        const dy: number = (y - h / 2) / (h / 2);
        const d: number = Math.sqrt(dx * dx + dy * dy);
        // 中心亮度从 70 提到 120，柔光感更明显
        const glow: number = Math.max(0, 1 - d) * 120 * k;
        nr = r + glow;
        ng = g + glow;
        nb = b + glow;
      } else if (name === '污渍') {
        let dark: number = 0;
        for (let s = 0; s < STAIN_COUNT; s++) {
          const dx: number = x - sx[s];
          const dy: number = y - sy[s];
          const d: number = Math.sqrt(dx * dx + dy * dy);
          if (d < sr[s]) {
            dark = Math.max(dark, sa[s] * (1 - d / sr[s]));
          }
        }
        const f: number = 1 - dark * k;
        nr = r * f;
        ng = g * f;
        nb = b * f;
      }
      px[i] = clampByte(nr);
      px[i + 1] = clampByte(ng);
      px[i + 2] = clampByte(nb);
    }
  }
  return bytes;
}
