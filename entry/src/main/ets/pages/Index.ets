import { HomePage } from './HomePage';
import { CategoryPage } from './CategoryPage';
import { SearchPage } from './SearchPage';
import { StickerPage } from './StickerPage';
import { MinePage } from './MinePage';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { WallpaperStore } from '../common/store/WallpaperStore';
import { EditGuard } from '../common/utils/EditGuard';
import { PrivacyConsentDialog } from '../common/components/PrivacyConsentDialog';
import { PRIVACY_CONSENT_VERSION } from '../common/constants/LegalTexts';
import { AuthManager } from '../common/net/AuthManager';
import { ApiConfig } from '../common/net/ApiConfig';
import { ImageCache } from '../common/net/ImageCache';
import { SystemApi, AppUpdateInfo } from '../common/net/SystemApi';
import { FavoriteSync } from '../common/net/FavoriteSync';
import { LoginPage } from './LoginPage';
import { RegisterPage } from './RegisterPage';
import { common, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';

/**
 * Index —— 主入口（底部 Tabs 导航 · 高级黑）
 *
 * 四个标签页：🏠 首页（大图卡片流）、📚 合辑、🐾 贴纸（宠物贴图）、👤 我的
 * 主题：近黑背景 #0F0F12 · 强调红 #C9333D（底色）/ #E8606A（深色底上的文字）· 精选金 #F0D08A
 *
 * 配色以应用市场「色彩对比度」审核项为准：正文文字与背景 ≥ 4.5:1，图标/标题 ≥ 3:1。
 * 改动配色时请跑 tools/contrast_audit.py 复核（详见《整改说明-1.1.0-色彩与动效.md》）。
 */
@Entry
@Component
struct Index {
  /** 当前选中的 Tab */
  @State currentIndex: number = 0;
  /** 独立搜索页（首页搜索胶囊进入；不切图库 tab） */
  @State showSearch: boolean = false;
  /** 全屏预览时隐藏底部 Tab 栏（沉浸式） */
  @State hideTabBar: boolean = false;
  /** 首页「更多」请求序号（随每次点击自增，编码进 AppStorage 请求值） */
  private pendingAlbumCounter: number = 0;
  /** 首页搜索请求序号（同词重复搜索也必然触发） */
  private pendingSearchCounter: number = 0;

  /**
   * 首次启动的隐私政策同意弹窗
   *
   * 审核硬要求（《审核指南》第 7.5 项）：「应用在首次启动、注册登录界面均未明确
   * 提示用户阅读隐私政策，不符合相关法律法规要求。」
   *
   * 所以它是盖在 Tabs **之上**的全屏遮罩，而不是一条可以划走的提示 ——
   * 未同意之前不得进入主界面。
   */
  @State showPrivacyConsent: boolean = false;

  /** 已同意的隐私政策版本（存本地；与 PRIVACY_CONSENT_VERSION 比对） */
  private readonly KEY_PRIVACY_CONSENT: string = 'privacy_consent_version';

  /**
   * 是否已登录（订阅 AppStorage，AuthManager 登录/登出时自动刷新）
   * 用于"我的"页显示用户名/登出、保存流程判断是否放行。
   */
  @StorageLink(ApiConfig.APP_KEY_LOGGED_IN) isLoggedIn: boolean = false;
  /**
   * 是否显示登录/注册覆盖层（按需触发，不挡主界面）。
   * 默认 false：所有人都能浏览预览图片。
   * 由"我的"页登录按钮、或保存图片时未登录的引导设置为 true。
   */
  @StorageLink(ApiConfig.APP_KEY_AUTH_OVERLAY) @Watch('onAuthOverlayChange') showAuthOverlay: boolean = false;
  /** 鉴权覆盖层当前显示登录还是注册 */
  @State authView: 'login' | 'register' = 'login';
  /** 上一次的覆盖层显示状态：只在 false → true 的「重新打开」时重置 authView */
  private lastAuthOverlay: boolean = false;

  /** Tab 文字（「合辑」改名「图库」，对标 Cuto） */
  private readonly tabLabels: string[] = ['首页', '图库', '贴纸', '我的'];

  aboutToAppear(): void {
    // 记录初始状态，避免启动时把「本来已打开」误判为一次重新打开
    this.lastAuthOverlay = this.showAuthOverlay;
    const ctx = getContext(this) as common.UIAbilityContext;
    PreferenceUtil.init(ctx);
    // 图片三级缓存初始化（cacheDir/remote-img）
    ImageCache.init(ctx);

    // 首次启动（或隐私政策文案更新后）先征得同意。
    // 记的是"已同意的版本号"而不是 true —— 文案改了要重新征得同意，
    // 这既是合规做法，也避免用户永远看不到更新后的政策。
    this.showPrivacyConsent =
      PreferenceUtil.getString(this.KEY_PRIVACY_CONSENT, '') !== PRIVACY_CONSENT_VERSION;

    // 鉴权管理：从本地恢复 token、注入 HttpClient 回调、同步登录态到 AppStorage。
    // 必须在 PreferenceUtil.init 之后调用（它依赖 PreferenceUtil 读写 token）。
    AuthManager.getInstance().init();

    // 收藏云同步（2026-10-25「收藏并入账号」）：挂上收藏变化回调，
    // 登录态下本地收藏/取消会增量同步云端。
    FavoriteSync.init();

    // 版本更新检查（2026-10-25 回访闭环）：
    // 合规要求 —— 未同意隐私政策前不得发起任何网络请求，所以只在同意后检查。
    if (!this.showPrivacyConsent) {
      this.checkAppUpdate();
    }

    // 统一数据源：壁纸目录已随包内置（LocalWallpapers），这里同步发布首屏 ——
    // 没有网络请求、没有骨架屏等待、不存在"连不上云端"的兜底分支。
    // 四个子页面只订阅 AppStorage 状态键，不直接访问数据源。
    WallpaperStore.getInstance().start();
  }

  /**
   * 登录/注册覆盖层显示状态变化
   *
   * 只在「关闭 → 打开」这一次重置到登录页：否则上次停在注册页，关闭后
   * 再从账号入口进来会直接落在注册页。覆盖层打开期间的「登录 ↔ 注册」
   * 切换不改这个状态，因此不会被重置。
   */
  onAuthOverlayChange(): void {
    const reopened: boolean = this.showAuthOverlay && !this.lastAuthOverlay;
    this.lastAuthOverlay = this.showAuthOverlay;
    if (reopened) {
      this.authView = 'login';
    }
  }

  /**
   * 系统返回键
   *
   * 优先级交给最上层覆盖层：图片编辑器 → 大图预览。
   * （贴纸专区已合并为「贴纸」Tab 页本身，不再是覆盖层，故不参与返回键接管。）
   *
   * 它们返回 true 表示已消费（例如弹出"放弃编辑？"或关闭覆盖层）；
   * 没有任何覆盖层时才返回 false，走系统默认行为（退出应用）。
   *
   * 此前没有这个拦截：在大图预览里按返回键会直接退出 App，
   * 在编辑器里按返回键会连编辑器带页面一起关掉，未保存的编辑全部丢失。
   */
  onBackPress(): boolean {
    return EditGuard.handleBack();
  }

  /**
   * 版本更新检查（2026-10-25 回访闭环，HANDOFF P1-6 收口）
   *
   * GET /versions/latest?platform=harmony&versionCode=N → 后端比对算 needUpdate。
   * 有更新弹窗提示（非强制不阻断使用，强制更新只给"立即更新"）；
   * 检查失败/无更新静默跳过 —— 版本提示是增强，不是依赖。
   */
  private async checkAppUpdate(): Promise<void> {
    let info: AppUpdateInfo | null = null;
    try {
      info = await SystemApi.checkUpdate();
    } catch {
      return;
    }
    if (info === null) {
      return;
    }
    const update: AppUpdateInfo = info;
    AlertDialog.show({
      title: `发现新版本 v${update.versionName}`,
      message: update.updateContent.length > 0 ? update.updateContent : '优化体验，修复已知问题',
      autoCancel: !update.forceUpdate,
      alignment: DialogAlignment.Center,
      buttons: update.forceUpdate
        ? [
          {
            value: '立即更新',
            action: (): void => {
              this.openUpdateLink(update.downloadUrl);
            }
          }
        ]
        : [
          {
            value: '稍后再说',
            action: (): void => {
            }
          },
          {
            value: '立即更新',
            action: (): void => {
              this.openUpdateLink(update.downloadUrl);
            }
          }
        ]
    });
  }

  /** 打开下载页（后台 app_versions.downloadUrl 配置的应用市场/网页地址） */
  private openUpdateLink(url: string): void {
    const fallback: () => void = (): void => {
      promptAction.showToast({ message: '暂时打不开更新页，请稍后在应用市场更新' });
    };
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = { action: 'ohos.want.action.viewData', uri: url };
      ctx.startAbility(want).catch((): void => {
        fallback();
      });
    } catch {
      fallback();
    }
  }

  /** Tab 系统符号图标（选中/未选中同一图标，靠颜色区分；对齐图标统一方案） */
  private tabSymbol(index: number): Resource {
    if (index === 1) return $r('sys.symbol.square_grid_2x2');
    if (index === 2) return $r('sys.symbol.face_smiling');
    if (index === 3) return $r('sys.symbol.person');
    return $r('sys.symbol.house');
  }

  /** 底部 Tab 栏：选中金色、未选中灰（Cuto 风格系统符号图标，无 emoji） */
  @Builder
  tabBarBuilder(index: number) {
    Column({ space: 2 }) {
      SymbolGlyph(this.tabSymbol(index))
        .fontColor([this.currentIndex === index ? '#F0D08A' : '#A8A8B5'])
        .fontSize(22)
      Text(this.tabLabels[index])
        .fontSize(10)
        .fontColor(this.currentIndex === index ? '#F0D08A' : '#A8A8B5')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
        TabContent() {
          HomePage({
            hideTabBar: (v: boolean) => { this.hideTabBar = v; },
            onMore: (slug: string) => {
              // 事件总线写 AppStorage（不依赖跨 tab 的 @Prop 投递：实测后者在
              // 「属性更新与 tab 显示同一帧」时 @Watch 不触发）
              this.pendingAlbumCounter = this.pendingAlbumCounter + 1;
              AppStorage.setOrCreate(ApiConfig.APP_KEY_OPEN_ALBUM,
                `${this.pendingAlbumCounter}:${slug}`);
              this.currentIndex = 1;
            },
            onSearch: (keyword: string) => {
              // 首页搜索 → 独立搜索页（不跳图库；keyword 为空时进入历史/热门态）
              this.showSearch = true;
            }
          })
        }
        .tabBar(this.tabBarBuilder(0))

        TabContent() {
          CategoryPage({
            hideTabBar: (v: boolean) => { this.hideTabBar = v; },
            onSearch: () => { this.showSearch = true; }
          })
        }
        .tabBar(this.tabBarBuilder(1))

        TabContent() {
          StickerPage()
        }
        .tabBar(this.tabBarBuilder(2))

        TabContent() {
          MinePage({ hideTabBar: (v: boolean) => { this.hideTabBar = v; } })
        }
        .tabBar(this.tabBarBuilder(3))
      }
      .onChange((index: number) => {
        this.currentIndex = index;
      })
      .barHeight(this.hideTabBar ? 0 : 56)
      .backgroundColor('#111114')
      .scrollable(false)

      // 独立搜索页：盖住 Tabs，关闭后仍停留在原 tab
      if (this.showSearch) {
        SearchPage({
          onClose: (): void => {
            this.showSearch = false;
          }
        })
      }

      // 首次启动的隐私政策弹窗：盖在 Tabs **之上**，未同意不得进入主界面
      if (this.showPrivacyConsent) {
        PrivacyConsentDialog({
          onAgree: () => {
            PreferenceUtil.setString(this.KEY_PRIVACY_CONSENT, PRIVACY_CONSENT_VERSION);
            this.showPrivacyConsent = false;
            // 同意后才允许联网行为：补一次版本检查
            this.checkAppUpdate();
          },
          onReject: () => {
            // 「不同意」必须真正退出应用 —— 只把弹窗关掉不算（审核要点 2）
            const ctx = getContext(this) as common.UIAbilityContext;
            ctx.terminateSelf();
          }
        })
      }

      // 登录/注册覆盖层：按需触发，不挡主界面。
      // 默认不显示——所有人都能浏览预览图片。
      // 由"我的"页登录按钮、或保存图片时未登录的引导设置为 true。
      if (!this.showPrivacyConsent && this.showAuthOverlay) {
        if (this.authView === 'login') {
          LoginPage({
            onGoRegister: () => { this.authView = 'register'; },
            onClose: () => { AuthManager.getInstance().hideAuthOverlay(); }
          })
        } else {
          RegisterPage({
            onGoLogin: () => { this.authView = 'login'; },
            onClose: () => { AuthManager.getInstance().hideAuthOverlay(); }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
  }
}
