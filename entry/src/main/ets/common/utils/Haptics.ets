import { vibrator } from '@kit.SensorServiceKit';

/**
 * Haptics —— 全局触感反馈（克制使用，只在关键节点）
 *
 * 为什么单独封装而不直接调 vibrator：
 *  1. 调用点多（收藏、裁剪吸附、保存成功、手势吸附等），统一入口便于调节时长/开关；
 *  2. 系统没有振动器（部分设备）或权限未授予时，错误在这里吞掉，业务代码零负担；
 *  3. 连续触发时自动并单（如拖把手反复"吸附"），避免马达嗡嗡作响。
 *
 * 需要权限 ohos.permission.VIBRATE（normal 级，module.json5 声明，安装即授予）。
 */
export class Haptics {
  /** 上次轻触感时间（毫秒），用于并单防抖 */
  private static lastLightMs: number = 0;
  /** 轻触感最小间隔（毫秒） */
  private static readonly LIGHT_MIN_GAP: number = 60;

  /**
   * 轻触（收藏切换、按钮轻点）：约 8ms
   * 60ms 内的重复调用自动并单
   */
  static light(): void {
    const now: number = Date.now();
    if (now - Haptics.lastLightMs < Haptics.LIGHT_MIN_GAP) {
      return;
    }
    Haptics.lastLightMs = now;
    Haptics.vibrate(8);
  }

  /** 中等触感（裁剪把手吸附边界、比例切换）：约 14ms */
  static medium(): void {
    Haptics.vibrate(14);
  }

  /** 成功触感（保存到相册完成）：两段式 12 + 22，模拟"确认"节奏 */
  static success(): void {
    Haptics.vibrate(12);
    setTimeout((): void => Haptics.vibrate(22), 90);
  }

  /** 按毫秒时长振动；任何异常（无权限/无马达）静默吞掉 */
  private static vibrate(duration: number): void {
    try {
      vibrator.startVibration({ type: 'time', duration: duration },
        { id: 0, usage: 'notification' }).catch((): void => {
          // 忽略：设备不支持/权限问题不影响视觉主流程
        });
    } catch (e) {
      // 同步异常同样吞掉
    }
  }
}
