import { bundleManager } from '@kit.AbilityKit';

/**
 * AppInfo —— 应用自身信息（版本号等）
 *
 * 用途：隐私政策/用户协议/关于页需要展示**真实**版本号。
 * 此前 MinePage 把 "v1.0.0" 硬编码在文案里，改版本时必然忘记同步，
 * 上架审核看到"应用信息与实际不符"是会直接驳回的。
 */
export class AppInfo {
  /** 版本号（读取失败时回退占位值，绝不抛错） */
  static version(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      console.error(`AppInfo version failed: ${JSON.stringify(e)}`);
      return '1.0.0';
    }
  }

  /** 版本名 + 版本号，形如 "1.0.0 (100)" */
  static versionFull(): string {
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return `${info.versionName} (${info.versionCode})`;
    } catch (e) {
      console.error(`AppInfo versionFull failed: ${JSON.stringify(e)}`);
      return '1.0.0';
    }
  }
}
