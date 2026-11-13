import { ApiConfig } from './ApiConfig';
import { promptAction } from '@kit.ArkUI';
import { HttpClient, ApiResponse } from './HttpClient';
import { PreferenceUtil } from '../utils/PreferenceUtil';
import { FavoriteSync } from './FavoriteSync';

/**
 * 后端登录/注册响应体
 */
export interface AuthResult {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  refresh_expires_in?: number;
  user_id?: number;
  username?: string;
}

/** 注册/登录请求体（ArkTS 要求对象字面量必须有显式类型） */
interface AuthRequestBody {
  username: string;
  password: string;
}

/** 刷新 token 请求体 */
interface RefreshRequestBody {
  refresh_token: string;
}

/**
 * AuthManager —— 鉴权与登录态管理（单例）
 *
 * 职责：
 *  1. 持有 access/refresh token（持久化在 PreferenceUtil），App 重启不丢登录态；
 *  2. 登录/注册/刷新接口走 HttpClient.rawRequest（不触发 401 重试，避免死循环）；
 *  3. 把"是否已登录"广播到 AppStorage(ApiConfig.APP_KEY_LOGGED_IN)，
 *     Index 页面用它做路由：未登录显示 LoginPage，已登录显示主界面；
 *  4. 向 HttpClient 注入取 token / 刷新 token / 登录失效三个回调。
 *
 * 使用前必须 init()（Index.aboutToAppear 里调用），它会注入回调并同步登录态到 AppStorage。
 */
export class AuthManager {
  private static instance: AuthManager | null = null;
  /** 内存缓存的 access_token，避免每次请求都读 Preferences */
  private accessToken: string = '';
  private refreshToken: string = '';
  /** 刷新中标记，防止并发请求同时触发多次刷新 */
  private refreshing: boolean = false;
  /**
   * "保存被登录拦下"标记：登录成功后提示用户再点一次保存。
   * 系统 SaveButton 的相册写权限是一次点击一次授权，登录无法在同一次点击里接着存。
   */
  private pendingSaveHint: boolean = false;

  private constructor() {}

  static getInstance(): AuthManager {
    if (AuthManager.instance === null) {
      AuthManager.instance = new AuthManager();
    }
    return AuthManager.instance;
  }

  /**
   * 初始化：从本地恢复 token，注入 HttpClient 回调，同步登录态。
   * 必须在 PreferenceUtil.init() 之后调用。
   */
  init(): void {
    this.accessToken = PreferenceUtil.getString(ApiConfig.KEY_ACCESS_TOKEN, '');
    this.refreshToken = PreferenceUtil.getString(ApiConfig.KEY_REFRESH_TOKEN, '');
    this.publishLoginState();
    // 重置覆盖层：启动时不应残留上次未完成的登录弹层
    this.hideAuthOverlay();

    // 注入回调，让 HttpClient 能拿 token / 自动刷新 / 通知登录失效
    HttpClient.setTokenGetter((): string => this.accessToken);
    HttpClient.setTokenRefresher((): Promise<boolean> => this.refresh());
    HttpClient.setOnAuthFailed((): void => { this.logout(); });
  }

  // ==================== 登录 / 注册 / 刷新 ====================

  /**
   * 注册（账号 + 密码）
   * @returns ApiResponse，失败时 code='USER_EXISTS' 表示用户名已占用
   */
  async register(username: string, password: string): Promise<ApiResponse<AuthResult>> {
    const url: string = this.urlOf(ApiConfig.PATH.REGISTER);
    const reqBody: AuthRequestBody = { username: username, password: password };
    const resp: ApiResponse<AuthResult> = await HttpClient.rawRequest<AuthResult>(
      'POST', url, { 'Content-Type': 'application/json' }, reqBody
    );
    // 注册成功不自动登录，让用户手动登录（简单注册流程）
    return resp;
  }

  /**
   * 登录（账号 + 密码）
   * 成功后持久化 token 并广播登录态。
   */
  async login(username: string, password: string): Promise<ApiResponse<AuthResult>> {
    const url: string = this.urlOf(ApiConfig.PATH.LOGIN);
    const reqBody: AuthRequestBody = { username: username, password: password };
    const resp: ApiResponse<AuthResult> = await HttpClient.rawRequest<AuthResult>(
      'POST', url, { 'Content-Type': 'application/json' }, reqBody
    );
    if (resp.ok && resp.data) {
      this.saveTokens(resp.data);
      if (resp.data.username) {
        PreferenceUtil.setString(ApiConfig.KEY_USERNAME, resp.data.username);
      }
      if (resp.data.user_id !== undefined) {
        PreferenceUtil.setString(ApiConfig.KEY_USER_ID, String(resp.data.user_id));
      }
      this.publishLoginState();
      // 收藏并入账号（2026-10-25）：本地收藏批量上云 + 云端收藏拉回合并。
      // 后台静默执行（fire-and-forget），失败不影响登录与本地收藏。
      FavoriteSync.onLoginSync();
      // 本次登录是否由"点保存但未登录"触发：先取标记，hideAuthOverlay 会清掉它
      const needSaveHint: boolean = this.pendingSaveHint;
      this.hideAuthOverlay();
      if (needSaveHint) {
        promptAction.showToast({ message: '登录成功，请再次点击保存' });
      }
    }
    return resp;
  }

  /**
   * 用 refresh_token 刷新 access_token。
   * @returns 是否刷新成功
   *
   * 并发保护：多个请求同时 401 时只发一次刷新，其余等结果。
   */
  async refresh(): Promise<boolean> {
    if (this.refreshToken.length === 0) {
      return false;
    }
    if (this.refreshing) {
      // 简单自旋等待正在进行的刷新（鸿蒙单线程事件循环，这里轮询几次即可）
      for (let i: number = 0; i < 20; i++) {
        await this.delay(50);
        if (!this.refreshing) {
          return this.accessToken.length > 0;
        }
      }
      return false;
    }
    this.refreshing = true;
    try {
      const url: string = this.urlOf(ApiConfig.PATH.REFRESH);
      const reqBody: RefreshRequestBody = { refresh_token: this.refreshToken };
      const resp: ApiResponse<AuthResult> = await HttpClient.rawRequest<AuthResult>(
        'POST', url, { 'Content-Type': 'application/json' }, reqBody
      );
      if (resp.ok && resp.data && resp.data.access_token) {
        // 刷新接口一般只下发新的 access_token，refresh_token 不变
        this.accessToken = resp.data.access_token;
        PreferenceUtil.setString(ApiConfig.KEY_ACCESS_TOKEN, this.accessToken);
        if (resp.data.refresh_token) {
          this.refreshToken = resp.data.refresh_token;
          PreferenceUtil.setString(ApiConfig.KEY_REFRESH_TOKEN, this.refreshToken);
        }
        return true;
      }
      return false;
    } catch {
      return false;
    } finally {
      this.refreshing = false;
    }
  }

  /** 登出：清 token + 广播未登录态（先通知服务端清 refresh_token，失败也不影响本地登出） */
  logout(): void {
    if (this.accessToken.length > 0) {
      // 不等待结果：本地登出必须立刻生效
      HttpClient.post<object>(ApiConfig.PATH.LOGOUT).catch((): void => {});
    }
    this.clearLocal();
  }

  /**
   * 注销账号（法规要求的自助注销入口）
   *
   * 服务端删除成功后清本地登录态；密码错误等失败情况原样返回给页面提示。
   */
  async deleteAccount(password: string): Promise<ApiResponse<boolean>> {
    interface DeleteBody {
      password: string;
    }
    const body: DeleteBody = { password: password };
    const resp: ApiResponse<boolean> = await HttpClient.request<boolean>(
      'DELETE', ApiConfig.PATH.DELETE_ACCOUNT, undefined, body);
    if (resp.ok) {
      this.clearLocal();
    }
    return resp;
  }

  /** 修改昵称 */
  async updateNickname(nickname: string): Promise<ApiResponse<object>> {
    interface NickBody {
      nickname: string;
    }
    const body: NickBody = { nickname: nickname };
    const resp: ApiResponse<object> = await HttpClient.request<object>(
      'PATCH', ApiConfig.PATH.USER_PROFILE, undefined, body);
    if (resp.ok) {
      PreferenceUtil.setString(ApiConfig.KEY_USERNAME, nickname);
      AppStorage.setOrCreate<string>('authNickname', nickname);
    }
    return resp;
  }

  /** 本地清理登录态（登出 / 注销共用） */
  private clearLocal(): void {
    this.accessToken = '';
    this.refreshToken = '';
    PreferenceUtil.remove(ApiConfig.KEY_ACCESS_TOKEN);
    PreferenceUtil.remove(ApiConfig.KEY_REFRESH_TOKEN);
    PreferenceUtil.remove(ApiConfig.KEY_USERNAME);
    PreferenceUtil.remove(ApiConfig.KEY_USER_ID);
    this.publishLoginState();
  }

  // ==================== 查询 ====================

  /** 是否已登录（有 access_token 即视为登录） */
  isLoggedIn(): boolean {
    return this.accessToken.length > 0;
  }

  /** 当前用户名（未登录返回空串） */
  getUsername(): string {
    return PreferenceUtil.getString(ApiConfig.KEY_USERNAME, '');
  }

  /** 当前用户 ID（未登录返回 -1） */
  getUserId(): number {
    const raw: string = PreferenceUtil.getString(ApiConfig.KEY_USER_ID, '');
    const n: number = Number(raw);
    return Number.isFinite(n) && n > 0 ? n : -1;
  }

  // ==================== 内部工具 ====================

  private saveTokens(r: AuthResult): void {
    this.accessToken = r.access_token;
    PreferenceUtil.setString(ApiConfig.KEY_ACCESS_TOKEN, this.accessToken);
    if (r.refresh_token) {
      this.refreshToken = r.refresh_token;
      PreferenceUtil.setString(ApiConfig.KEY_REFRESH_TOKEN, this.refreshToken);
    }
  }

  /** 把登录态同步到 AppStorage，Index 路由订阅它 */
  private publishLoginState(): void {
    AppStorage.setOrCreate<boolean>(ApiConfig.APP_KEY_LOGGED_IN, this.isLoggedIn());
  }

  // ==================== 登录覆盖层（按需触发） ====================

  /**
   * 弹出登录/注册覆盖层（不挡主界面，盖在最上层）。
   * 用于"我的"页点击登录、或保存图片时未登录的引导。
   */
  showAuthOverlay(): void {
    AppStorage.setOrCreate<boolean>(ApiConfig.APP_KEY_AUTH_OVERLAY, true);
  }

  /** 关闭登录/注册覆盖层（视为放弃本次操作，清掉"登录后提示再保存"标记） */
  hideAuthOverlay(): void {
    this.pendingSaveHint = false;
    AppStorage.setOrCreate<boolean>(ApiConfig.APP_KEY_AUTH_OVERLAY, false);
  }

  /**
   * 保存流程的登录闸门：未登录则弹登录层，并登记"登录成功后提示再点一次保存"。
   * 调用方：`if (!AuthManager.getInstance().requireLoginForSave()) { 提示并 return; }`
   * @returns true=已登录可继续保存；false=已弹登录层，本次保存中止
   */
  requireLoginForSave(): boolean {
    if (this.isLoggedIn()) {
      return true;
    }
    this.pendingSaveHint = true;
    this.showAuthOverlay();
    return false;
  }

  /**
   * 保存/下载流程的登录闸门：未登录则弹覆盖层并返回 false。
   * 调用方：`if (!AuthManager.getInstance().requireLogin()) return;`
   * @returns true=已登录可继续，false=已弹登录页，中止本次保存
   */
  requireLogin(): boolean {
    if (this.isLoggedIn()) {
      return true;
    }
    this.showAuthOverlay();
    return false;
  }

  private urlOf(path: string): string {
    const base: string = ApiConfig.BASE_URL.endsWith('/')
      ? ApiConfig.BASE_URL.slice(0, -1) : ApiConfig.BASE_URL;
    return `${base}${path.startsWith('/') ? path : `/${path}`}`;
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => setTimeout(resolve, ms));
  }
}
