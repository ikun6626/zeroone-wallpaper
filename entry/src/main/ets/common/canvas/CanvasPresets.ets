import { Size, Rect, ViewMath } from './ViewTransform';

/**
 * CanvasPresets —— 画布比例 / 模板预设（纯函数，不依赖任何系统 API）
 *
 * 用途：阶段 5「轻编辑」工作台里"比例/模板"那一栏的唯一数据源，
 * 同时给"安全区"提供依据 —— 锁屏时钟、桌面图标、系统手势条会压住的区域，
 * 让用户知道重要内容该放在哪里（Cuto 的模板感很大一部分来自这里）。
 *
 * 单位约定：尺寸一律像素（px），安全区用相对画布的归一化值（0~1），
 * 与 `common/canvas` 其它模块一致。
 */

/** 安全区（相对画布的归一化内缩量） */
export interface SafeArea {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

/** 画布预设 */
export interface CanvasPreset {
  /** 稳定标识（用于持久化与配置） */
  id: string;
  /** 展示名 */
  label: string;
  /** 宽/高比；0 表示跟随设备屏幕 */
  ratio: number;
  /** 安全区 */
  safe: SafeArea;
}

/** 预设 id 常量（避免各处写字符串字面量） */
export class PresetIds {
  static readonly DEVICE: string = 'device';
  static readonly SQUARE: string = 'square';
  static readonly CLASSIC: string = 'classic';
  static readonly WIDE: string = 'wide';
  static readonly FREE: string = 'free';
}

const SAFE_DEVICE: SafeArea = { top: 0.08, bottom: 0.08, left: 0.05, right: 0.05 };
const SAFE_NEUTRAL: SafeArea = { top: 0.04, bottom: 0.04, left: 0.04, right: 0.04 };

/** 全部预设（顺序即 UI 展示顺序） */
const PRESETS: CanvasPreset[] = [
  { id: PresetIds.DEVICE, label: '手机屏幕', ratio: 0, safe: SAFE_DEVICE },
  { id: PresetIds.SQUARE, label: '1:1', ratio: 1, safe: SAFE_NEUTRAL },
  { id: PresetIds.CLASSIC, label: '4:3', ratio: 4 / 3, safe: SAFE_NEUTRAL },
  { id: PresetIds.WIDE, label: '16:9', ratio: 16 / 9, safe: SAFE_NEUTRAL },
  { id: PresetIds.FREE, label: '自由', ratio: 0, safe: SAFE_NEUTRAL }
];

export class CanvasPresets {
  /** 全部预设（返回副本，调用方改不坏内部表） */
  static all(): CanvasPreset[] {
    const out: CanvasPreset[] = [];
    for (let i = 0; i < PRESETS.length; i++) {
      out.push(PRESETS[i]);
    }
    return out;
  }

  /** 按 id 取预设；未知 id 回退到"手机屏幕" */
  static byId(id: string): CanvasPreset {
    for (let i = 0; i < PRESETS.length; i++) {
      if (PRESETS[i].id === id) {
        return PRESETS[i];
      }
    }
    return PRESETS[0];
  }

  /** 是否为"跟随设备屏幕"的预设 */
  static isDevice(preset: CanvasPreset): boolean {
    if (preset.id === PresetIds.DEVICE) {
      return true;
    }
    // 自由模式沿用当前画布，同样以设备尺寸为基准
    return preset.id === PresetIds.FREE;
  }

  /**
   * 预设对应的输出尺寸
   *
   * 固定比例的规则与裁剪一致：取"能塞进设备屏幕的最大同比例矩形"，
   * 这样导出尺寸永远不会大于屏幕，也不会出现半像素导致的比例偏差。
   */
  static sizeFor(preset: CanvasPreset, device: Size): Size {
    if (preset.ratio <= 0) {
      return { width: Math.round(device.width), height: Math.round(device.height) };
    }
    let width: number = Math.min(device.width, device.height * preset.ratio);
    let height: number = width / preset.ratio;
    if (height > device.height) {
      height = device.height;
      width = height * preset.ratio;
    }
    return { width: Math.round(width), height: Math.round(height) };
  }

  /** 输出尺寸 + 长边护栏（4096），导出前统一过这一道 */
  static sizeForExport(preset: CanvasPreset, device: Size, maxLongEdge: number): Size {
    const raw: Size = CanvasPresets.sizeFor(preset, device);
    return ViewMath.limitLongEdge(raw.width, raw.height, maxLongEdge);
  }

  /** 安全区矩形（像素） */
  static safeRect(preset: CanvasPreset, size: Size): Rect {
    const x: number = size.width * preset.safe.left;
    const y: number = size.height * preset.safe.top;
    const w: number = size.width * (1 - preset.safe.left - preset.safe.right);
    const h: number = size.height * (1 - preset.safe.top - preset.safe.bottom);
    return { x: x, y: y, width: Math.max(0, w), height: Math.max(0, h) };
  }
}
