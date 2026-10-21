import http from '@ohos.net.http';
import { BusinessError } from '@ohos.base';
import { ApiConfig } from './ApiConfig';

/**
 * 统一接口返回结构（与后端契约一致）
 * - 成功：ok=true，data 为业务数据
 * - 失败：ok=false，code/message 为错误码与可读说明
 */
export interface ApiResponse<T> {
  ok: boolean;
  status: number;          // HTTP 状态码
  code?: string;           // 业务错误码（如 USER_EXISTS / AUTH_FAILED）
  message?: string;        // 人类可读说明
  data?: T;                // 业务数据
}

/**
 * 后端响应体通用结构（ArkTS 要求对象字面量必须有显式类型）
 * - 成功：可能 { data: ... } 或直接是数据对象
 * - 失败：{ code, message }
 */
interface ServerResponseBody {
  code?: string;
  message?: string;
  data?: object;
}

/**
 * HttpClient —— 基于 @ohos.net.http 的轻量封装
 *
 * 职责：
 *  1. 统一拼 URL、注入 JSON Header、超时；
 *  2. 自动带 Authorization: Bearer <access_token>（由 AuthManager 注入取 Token 的回调）；
 *  3. 遇 401/TOKEN_EXPIRED 时自动刷新一次 Token 并重试，仍失败则清登录态；
 *  4. 把后端 { code, message, ... } 统一翻译成 ApiResponse，调用方只关心 ok/data/code。
 *
 * 设计说明（避免循环依赖）：
 *  AuthManager 依赖 HttpClient 发请求，HttpClient 又要拿 AuthManager 的 Token ——
 *  这里用两个回调（tokenGetter / tokenRefresher）解耦：
 *  AuthManager 初始化时把回调塞进来，HttpClient 不直接 import AuthManager。
 */
export class HttpClient {
  private static tokenGetter: (() => string) | null = null;
  private static tokenRefresher: (() => Promise<boolean>) | null = null;
  private static onAuthFailed: (() => void) | null = null;

  /** AuthManager 初始化时注入：取当前 access_token */
  static setTokenGetter(fn: () => string): void {
    HttpClient.tokenGetter = fn;
  }

  /** AuthManager 初始化时注入：刷新 token（返回是否成功） */
  static setTokenRefresher(fn: () => Promise<boolean>): void {
    HttpClient.tokenRefresher = fn;
  }

  /** 登录态彻底失效时的回调（AuthManager 清登录态 + 跳登录页） */
  static setOnAuthFailed(fn: () => void): void {
    HttpClient.onAuthFailed = fn;
  }

  /** GET */
  static get<T>(path: string, query?: Record<string, string>): Promise<ApiResponse<T>> {
    return HttpClient.request<T>('GET', path, query, undefined);
  }

  /** POST */
  static post<T>(path: string, body?: object, query?: Record<string, string>): Promise<ApiResponse<T>> {
    return HttpClient.request<T>('POST', path, query, body);
  }

  /** DELETE */
  static delete<T>(path: string, query?: Record<string, string>): Promise<ApiResponse<T>> {
    return HttpClient.request<T>('DELETE', path, query, undefined);
  }

  /**
   * 核心请求方法（带 Token 注入 + 401 自动刷新重试）
   *
   * @param allowRetry 401 时是否允许刷新重试（登录/刷新接口本身不应重试）
   */
  static async request<T>(
    method: string,
    path: string,
    query?: Record<string, string>,
    body?: object,
    allowRetry: boolean = true
  ): Promise<ApiResponse<T>> {
    const url: string = HttpClient.buildUrl(path, query);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const token: string = HttpClient.tokenGetter ? HttpClient.tokenGetter() : '';
    if (token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    const resp: ApiResponse<T> = await HttpClient.rawRequest<T>(method, url, headers, body);

    // 401 且非"刷新接口本身"：尝试刷新一次再重试
    if (resp.status === 401 && allowRetry && HttpClient.tokenRefresher) {
      const refreshed: boolean = await HttpClient.tokenRefresher();
      if (refreshed) {
        const newToken: string = HttpClient.tokenGetter ? HttpClient.tokenGetter() : '';
        if (newToken.length > 0) {
          headers['Authorization'] = `Bearer ${newToken}`;
        }
        return HttpClient.rawRequest<T>(method, url, headers, body);
      }
      // 刷新失败 → 登录态失效
      if (HttpClient.onAuthFailed) {
        HttpClient.onAuthFailed();
      }
    }
    return resp;
  }

  /**
   * 底层单次请求（无 Token、无重试）—— 供 AuthManager 的登录/注册/刷新接口使用，
   * 避免这些接口自身触发 401 重试导致死循环。
   */
  static async rawRequest<T>(
    method: string,
    url: string,
    headers: Record<string, string>,
    body?: object
  ): Promise<ApiResponse<T>> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method as http.RequestMethod,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: ApiConfig.CONNECT_TIMEOUT,
        readTimeout: ApiConfig.READ_TIMEOUT,
        usingCache: false
      };
      if (body !== undefined) {
        options.extraData = JSON.stringify(body);
      }

      const res: http.HttpResponse = await req.request(url, options);
      const status: number = res.responseCode;
      const text: string = (typeof res.result === 'string') ? res.result : '';

      return HttpClient.parseResponse<T>(status, text);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      // 网络层错误（断网、超时、DNS 失败等）统一翻译
      return {
        ok: false,
        status: 0,
        code: 'NETWORK_ERROR',
        message: `网络请求失败：${err.message ?? '请检查网络连接'}`
      };
    } finally {
      req.destroy();
    }
  }

  /** 把后端返回体翻译成 ApiResponse */
  private static parseResponse<T>(status: number, text: string): ApiResponse<T> {
    let body: ServerResponseBody | null = null;
    try {
      if (text.length > 0) {
        body = JSON.parse(text) as ServerResponseBody;
      }
    } catch {
      // 非 JSON（如 502 网关返回 HTML）
      return {
        ok: false,
        status,
        code: 'BAD_RESPONSE',
        message: text.length > 0 ? text.substring(0, 200) : `HTTP ${status}`
      };
    }

    // 2xx 视为成功；后端约定成功时不带 code 字段，data 平铺或整体即数据
    if (status >= 200 && status < 300) {
      // 后端成功响应可能直接是数据对象，也可能 { data: ... }
      const data: T | undefined = (body && body.data !== undefined)
        ? body.data as T
        : (body as T);
      return { ok: true, status, data };
    }

    // 错误：后端返回 { code, message }
    return {
      ok: false,
      status,
      code: (body && body.code) ? body.code : `HTTP_${status}`,
      message: (body && body.message) ? body.message : `HTTP ${status}`
    };
  }

  /** 拼 URL + query string */
  private static buildUrl(path: string, query?: Record<string, string>): string {
    const base: string = ApiConfig.BASE_URL.endsWith('/')
      ? ApiConfig.BASE_URL.slice(0, -1)
      : ApiConfig.BASE_URL;
    const p: string = path.startsWith('/') ? path : `/${path}`;
    let url: string = `${base}${p}`;
    if (query) {
      const pairs: string[] = [];
      Object.keys(query).forEach((k: string) => {
        const v: string = query[k];
        if (v !== undefined && v !== null) {
          pairs.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
        }
      });
      if (pairs.length > 0) {
        url += `?${pairs.join('&')}`;
      }
    }
    return url;
  }
}
