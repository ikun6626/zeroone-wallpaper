/**
 * ApiConfig —— 接口配置（对接自建管理后台）
 *
 * 后端：NestJS，已部署阿里云 ECS，域名已备案 + HTTPS。
 *  - App 开放接口前缀：/api/v1（公开，无需鉴权）
 *  - 响应统一信封：{ code: 0, message: "success", data: ... }
 *
 * 登录/注册相关路径暂时保留（管理后台暂无 App 用户体系，
 * 对接"已有账号体系"时把 LOGIN_BASE_URL 指向账号服务即可）。
 */

/** 接口路径常量类型（ArkTS 要求对象字面量必须有显式类型） */
interface ApiPath {
  BANNERS: string;
  CATEGORIES: string;
  WALLPAPERS: string;
  FEEDBACK: string;
  VERSION_LATEST: string;
  DAILY_FEATURED: string;
  /** 合辑列表（后台可配置，改合辑不发版） */
  ALBUMS: string;
  /** 首页编排：每日精选大卡 + 首页合辑位 */
  HOME_COMPOSITION: string;
  /** 主色清单（颜色筛选 chip） */
  COLORS: string;
  /** 实时统计（「我的」页：已发布壁纸数、启用合辑数） */
  STATS: string;
  /** 公告列表（管理后台「公告管理」维护） */
  NOTICES: string;
  // —— App 用户体系（后端已上线：注册/登录/刷新/资料/改名/登出/注销） ——
  REGISTER: string;
  LOGIN: string;
  REFRESH: string;
  USER_PROFILE: string;
  LOGOUT: string;
  DELETE_ACCOUNT: string;
  // —— 用户收藏（2026-10-25「收藏并入账号」） ——
  /** 收藏/取消收藏单张的路径前缀（拼接 /:wallpaperId） */
  FAVORITES: string;
  /** 我的收藏（分页） */
  FAVORITES_MY: string;
  /** 登录时批量合并本地收藏 */
  FAVORITES_BATCH: string;
}

export class ApiConfig {
  /**
   * 后端 API 基础地址（正式域名，已备案 + HTTPS）。
   * 本地联调时可临时改为 'http://<your-server>/api/v1'。
   */
  static readonly BASE_URL: string = 'https://www.gqscc.cn/api/v1';

  /** 连接超时（毫秒） */
  static readonly CONNECT_TIMEOUT: number = 10000;
  /** 读取超时（毫秒） */
  static readonly READ_TIMEOUT: number = 20000;

  /** 壁纸列表分页大小（与后端上限 50 保持一致以内） */
  static readonly PAGE_SIZE: number = 20;

  /** access_token 在本地 Preferences 里的存储键（用户体系预留） */
  static readonly KEY_ACCESS_TOKEN: string = 'auth_access_token';
  /** refresh_token 在本地 Preferences 里的存储键（用户体系预留） */
  static readonly KEY_REFRESH_TOKEN: string = 'auth_refresh_token';
  /** 登录用户名存储键（用户体系预留） */
  static readonly KEY_USERNAME: string = 'auth_username';
  /** 登录用户 ID 存储键（用户体系预留） */
  static readonly KEY_USER_ID: string = 'auth_user_id';

  /** AppStorage 中"是否已登录"的镜像键 */
  static readonly APP_KEY_LOGGED_IN: string = 'isLoggedIn';
  /** AppStorage 中"是否显示登录/注册覆盖层"的键（按需触发，不挡主界面） */
  static readonly APP_KEY_AUTH_OVERLAY: string = 'showAuthOverlay';
  /** AppStorage 中"请求图库页打开合辑"的键（首页「更多」事件总线，值为「序号:slug」） */
  static readonly APP_KEY_OPEN_ALBUM: string = 'openAlbumReq';
  /** AppStorage 中"请求图库页打开全库搜索"的键（首页搜索事件总线，值为「序号:关键词」） */
  static readonly APP_KEY_OPEN_SEARCH: string = 'openSearchReq';

  /** 接口路径常量（集中管理，避免拼接出错） */
  static readonly PATH: ApiPath = {
    BANNERS: '/banners',
    CATEGORIES: '/categories',
    WALLPAPERS: '/wallpapers',
    FEEDBACK: '/feedback',
    VERSION_LATEST: '/versions/latest',
    DAILY_FEATURED: '/daily/featured',
    ALBUMS: '/albums',
    HOME_COMPOSITION: '/home/composition',
    COLORS: '/colors',
    STATS: '/stats',
    NOTICES: '/notices',
    // —— App 用户体系 ——
    REGISTER: '/auth/register',
    LOGIN: '/auth/login',
    REFRESH: '/auth/refresh',
    USER_PROFILE: '/auth/profile',
    LOGOUT: '/auth/logout',
    DELETE_ACCOUNT: '/auth/account',
    // —— 用户收藏 ——
    FAVORITES: '/favorites',
    FAVORITES_MY: '/favorites/my',
    FAVORITES_BATCH: '/favorites/batch'
  };
}
