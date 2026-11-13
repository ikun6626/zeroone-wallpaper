import { ApiConfig } from './ApiConfig';
import { HttpClient, ApiResponse } from './HttpClient';
import { AppInfo } from '../utils/AppInfo';

/** 后端公告 JSON 结构（GET /notices，后端已按 enabled/时间窗过滤并按 sort 排序） */
interface ApiNotice {
  id: number;
  title: string;
  content: string;
  type?: string | null;
  createdAt?: string | null;
}

/** 版本检查 JSON 结构（GET /versions/latest，后台未配置版本时 data 为 null） */
interface ApiVersion {
  versionCode: number;
  versionName: string;
  updateContent: string | null;
  downloadUrl: string | null;
  forceUpdate?: boolean;
  needUpdate?: boolean;
}

/** 公告条目（App 内部模型） */
export class NoticeItem {
  id: number = 0;
  title: string = '';
  content: string = '';
  /** 公告类型（NOTICE/ACTIVITY/POPUP；仅用于角标展示） */
  type: string = '';
  /** ISO 时间串（页面只取日期部分展示） */
  createdAt: string = '';
}

/** 版本检查结果 */
export class AppUpdateInfo {
  versionCode: number = 0;
  versionName: string = '';
  updateContent: string = '';
  downloadUrl: string = '';
  forceUpdate: boolean = false;
  needUpdate: boolean = false;
}

/**
 * SystemApi —— 系统服务接口封装（公告 / 版本检查）
 *
 * 2026-10-25「回访闭环」第一批：后台 notices、app-versions 模块此前已建好，
 * 这里补 App 端封装。意见反馈已由 MinePage 直连 /feedback，不在此重复。
 */
export class SystemApi {
  /** 拉取公告列表（失败/为空返回空数组，页面按"暂无公告"展示） */
  static async fetchNotices(): Promise<NoticeItem[]> {
    const resp: ApiResponse<ApiNotice[]> = await HttpClient.get<ApiNotice[]>(ApiConfig.PATH.NOTICES);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return [];
    }
    const out: NoticeItem[] = [];
    const list: ApiNotice[] = resp.data;
    for (let i = 0; i < list.length; i++) {
      const n: ApiNotice = list[i];
      if (n === null || n === undefined || typeof n.title !== 'string' || n.title.length === 0) {
        continue;
      }
      const item = new NoticeItem();
      item.id = typeof n.id === 'number' ? n.id : i;
      item.title = n.title;
      item.content = typeof n.content === 'string' ? n.content : '';
      item.type = (n.type !== null && n.type !== undefined && typeof n.type === 'string') ? n.type : '';
      item.createdAt = (n.createdAt !== null && n.createdAt !== undefined && typeof n.createdAt === 'string')
        ? n.createdAt : '';
      out.push(item);
    }
    return out;
  }

  /**
   * 版本更新检查（带当前 versionCode，由后端计算 needUpdate）。
   * 失败、后台未配置版本、或无更新时返回 null —— 调用方静默跳过即可。
   */
  static async checkUpdate(): Promise<AppUpdateInfo | null> {
    const query: Record<string, string> = {
      'platform': 'harmony',
      'versionCode': String(AppInfo.versionCode())
    };
    const resp: ApiResponse<ApiVersion | null> =
      await HttpClient.get<ApiVersion | null>(ApiConfig.PATH.VERSION_LATEST, query);
    if (!resp.ok || resp.data === undefined || resp.data === null) {
      return null;
    }
    const v: ApiVersion = resp.data;
    if (typeof v.versionCode !== 'number' || typeof v.versionName !== 'string') {
      return null;
    }
    const info = new AppUpdateInfo();
    info.versionCode = v.versionCode;
    info.versionName = v.versionName;
    info.updateContent = (v.updateContent !== null && v.updateContent !== undefined)
      ? v.updateContent : '';
    info.downloadUrl = (v.downloadUrl !== null && v.downloadUrl !== undefined)
      ? v.downloadUrl : '';
    info.forceUpdate = v.forceUpdate === true;
    // 后端给了 needUpdate 就信它；没给时按 versionCode 自行比较（双保险）
    info.needUpdate = (v.needUpdate === true) || info.versionCode > AppInfo.versionCode();
    if (!info.needUpdate || info.downloadUrl.length === 0) {
      return null;
    }
    return info;
  }
}
