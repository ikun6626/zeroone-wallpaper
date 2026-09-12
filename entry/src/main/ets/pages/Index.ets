import { HomePage } from './HomePage';
import { CategoryPage } from './CategoryPage';
import { StickerPage } from './StickerPage';
import { MinePage } from './MinePage';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { WallpaperStore } from '../common/store/WallpaperStore';
import { EditGuard } from '../common/utils/EditGuard';
import { common } from '@kit.AbilityKit';

/**
 * Index —— 主入口（底部 Tabs 导航 · 高级黑）
 *
 * 四个标签页：🏠 首页（大图卡片流）、📚 合辑、🐾 贴纸（宠物贴图）、👤 我的
 * 主题：近黑背景 #0F0F12 · 强调粉 #FF6B6B · 精选金 #E6C07E
 */
@Entry
@Component
struct Index {
  /** 当前选中的 Tab */
  @State currentIndex: number = 0;
  /** 全屏预览时隐藏底部 Tab 栏（沉浸式） */
  @State hideTabBar: boolean = false;

  /** Tab 图标（emoji） */
  private readonly tabIcons: string[] = ['🏠', '📚', '🐾', '👤'];
  /** Tab 文字 */
  private readonly tabLabels: string[] = ['首页', '合辑', '贴纸', '我的'];

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    PreferenceUtil.init(ctx);
    // 统一数据源：先同步读本地缓存喂给 UI（秒开，不再先清空导致黑屏），
    // 再后台刷新云数据（空表播种 / 云端不可用则内置数据兜底并标记离线态）。
    // 四个子页面只订阅 AppStorage 状态键，不直接访问云库。
    WallpaperStore.getInstance().start();
  }

  /**
   * 系统返回键
   *
   * 优先级交给最上层覆盖层：设为壁纸引导 → 图片编辑器 → 贴纸工作台/画板 → 大图预览。
   * 它们返回 true 表示已消费（例如弹出"放弃编辑？"或关闭覆盖层）；
   * 没有任何覆盖层时才返回 false，走系统默认行为（退出应用）。
   *
   * 此前没有这个拦截：在大图预览里按返回键会直接退出 App，
   * 在编辑器里按返回键会连编辑器带页面一起关掉，未保存的编辑全部丢失。
   */
  onBackPress(): boolean {
    return EditGuard.handleBack();
  }

  /** 底部 Tab 栏：选中粉色、未选中灰 */
  @Builder
  tabBarBuilder(index: number, icon: string, label: string) {
    Column({ space: 2 }) {
      Text(icon)
        .fontSize(22)
      Text(label)
        .fontSize(10)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .foregroundColor(this.currentIndex === index ? '#FF6B6B' : '#7A7A85')
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        HomePage({ hideTabBar: (v: boolean) => { this.hideTabBar = v; } })
      }
      .tabBar(this.tabBarBuilder(0, this.tabIcons[0], this.tabLabels[0]))

      TabContent() {
        CategoryPage({ hideTabBar: (v: boolean) => { this.hideTabBar = v; } })
      }
      .tabBar(this.tabBarBuilder(1, this.tabIcons[1], this.tabLabels[1]))

      TabContent() {
        StickerPage()
      }
      .tabBar(this.tabBarBuilder(2, this.tabIcons[2], this.tabLabels[2]))

      TabContent() {
        MinePage({ hideTabBar: (v: boolean) => { this.hideTabBar = v; } })
      }
      .tabBar(this.tabBarBuilder(3, this.tabIcons[3], this.tabLabels[3]))
    }
    .onChange((index: number) => {
      this.currentIndex = index;
    })
    .barHeight(this.hideTabBar ? 0 : 56)
    .backgroundColor('#111114')
    .scrollable(false)
  }
}
