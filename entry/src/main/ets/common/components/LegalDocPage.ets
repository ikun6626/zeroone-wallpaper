import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AppInfo } from '../utils/AppInfo';
import { EditGuard } from '../utils/EditGuard';
import { WallpaperStore } from '../store/WallpaperStore';
import { CloudDBUtil } from '../utils/CloudDBUtil';
import { CloudWallpapers } from '../constants/CloudWallpapers';

/** 文档类型 */
enum DocKind {
  PRIVACY = 0,
  TERMS = 1,
  ABOUT = 2
}

/**
 * LegalDocPage —— 隐私政策 / 用户协议 / 关于与版权（全屏覆盖）
 *
 * 为什么必须有：
 *  1. 应用市场上架审核的硬性要求 —— 无隐私政策、无用户协议、无版本号/主体信息
 *     会直接驳回（此前项目里一个都没有）；
 *  2. 图片来源必须署名 —— 内置壁纸来自公开免费图库，不声明来源有版权风险；
 *  3. 用户可以自查"这个 App 到底收了我什么数据"，这是信任的基础。
 *
 * 实现说明：文档为内置文本（不依赖网络文档站，保证离线可看、审核期也可看）；
 * 版本号走 AppInfo 实时读取，避免像以前那样把 v1.0.0 硬编码在文案里。
 */
@Component
export struct LegalDocPage {
  onClose: () => void = () => {};
  /** 当前文档 */
  @State kind: number = DocKind.PRIVACY;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  /** 更新日期（改文案时同步改这里，审核会看） */
  private readonly updatedAt: string = '2026-01-01';

  private readonly privacy: string[] = [
    '更新日期：2026-01-01\n生效日期：2026-01-01',
    '一、我们收集哪些信息\nZeroOne 壁纸不需要注册或登录，不收集你的姓名、手机号、身份证号、通讯录、位置等任何个人身份信息。',
    '二、信息如何存储\n1. 你的收藏记录仅保存在本机（应用私有存储），不会上传到服务器，卸载应用即被删除。\n2. 应用会在本机保存一份壁纸列表缓存，用于加快下次启动速度，可随时在「关于」中清除。',
    '三、权限使用说明\n1. 保存到相册：仅在您主动点击保存按钮时，通过系统安全控件（SaveButton）获得一次性的临时写入授权，用于把图片存入系统相册。应用不会读取你的相册内容用于其他用途，也不会在后台写入。\n2. 网络访问：用于从云端获取壁纸列表与图片资源。\n3. 传感器（方向）：仅在动态壁纸预览时用于实现轻微视差效果，可在预览界面直接退出。',
    '四、第三方服务\n壁纸数据托管于华为 AppGallery Connect 云数据库/云存储。图片内容由上述服务按网络请求正常传输，不包含你的个人信息。',
    '五、我们不会做的事\n不向任何第三方出售、出租或分享你的个人信息；不进行用户画像与个性化广告推送；不索取与功能无关的权限。',
    '六、未成年人保护\n本应用内容适合所有年龄段，不设付费与社交功能，不收集任何用户身份信息。',
    '七、政策更新\n如本政策发生变更，我们会在应用内更新本页内容并调整更新日期。',
    '八、联系我们\n如对本政策有任何疑问，请联系：zeroone@example.com。'
  ];

  private readonly terms: string[] = [
    '更新日期：2026-01-01',
    '一、服务内容\nZeroOne 壁纸为你提供壁纸浏览、收藏、图片编辑与贴纸创作等本机功能。应用内所有功能均可免费使用。',
    '二、使用规范\n1. 请勿将本应用用于任何违法或侵害他人权益的用途；\n2. 请勿对应用进行反向工程、恶意篡改或传播篡改版本；\n3. 使用图片编辑与贴纸功能时，请确保你对所用素材拥有合法权利。',
    '三、知识产权\n1. 应用界面、图标、文案及自研功能归开发者所有；\n2. 内置壁纸图片来自公开免费图库（详见「关于与版权」），版权归原作者所有；\n3. 你使用本应用创作的图片归你所有，应用不会上传或留存你的创作内容。',
    '四、免责声明\n1. 壁纸图片来自第三方免费图库，我们已尽力筛选合规内容，如仍有不当内容请通过邮箱告知，我们会第一时间下架；\n2. 因网络、系统或设备原因导致的功能不可用，我们会尽力修复，但不承担由此产生的间接损失。',
    '五、关于"设为壁纸"\n受系统限制，第三方应用无法直接替换系统壁纸。应用提供"存为锁屏图/桌面图"并给出设置步骤引导，最终设置需你在系统「图库」中完成。',
    '六、协议变更\n协议如有更新将在本页公布，继续使用即视为接受更新后的条款。',
    '七、联系方式\nzeroone@example.com'
  ];

  private readonly about: string[] = [
    'ZeroOne 壁纸 —— 宠物主题的高级壁纸商城：精选猫猫狗狗与萌宠壁纸，穿插自然风光、极简风格等好图，并支持抠图贴纸与图片创作。',
    '图片来源与版权声明\n1. 内置占位壁纸来自公开免费图库（Picsum / Pexels / Wikimedia Commons 等），版权归原作者所有；\n2. 应用内图片仅用于壁纸展示与个人使用，请勿用于商业用途；\n3. 如你是某张图片的权利人且不希望它出现在本应用中，请邮件联系，我们会在核实后立即移除。',
    '第三方组件\n本应用使用 HarmonyOS 官方能力（ArkUI、Image Kit、Cloud Foundation Kit 等），未使用任何第三方广告或数据采集 SDK。',
    '备案与主体信息\n应用名称：ZeroOne 壁纸\n开发者：ZeroOne\n联系邮箱：zeroone@example.com\n（正式上架前请在此补充备案号/统一社会信用代码等主体信息）'
  ];

  /**
   * 写入云端壁纸数据（长按版本号触发，开发期工具，上架前可移除）
   *
   * 之所以做成应用内入口而不是手工导 CSV：字段名大小写、Long 类型、主键唯一性
   * 全由 SDK 保证，一批一次成型；而且是 upsert 语义，重复执行不会产生重复记录。
   */
  private confirmSeed(): void {
    const total: number = CloudWallpapers.all().length;
    promptAction.showDialog({
      title: '写入云端壁纸数据',
      message: `将把 ${total} 条壁纸记录写入云数据库（同 id 覆盖，可重复执行）。确认开始？`,
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '开始写入', color: '#FF6B6B' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.seedCloud();
      }
    }).catch(() => {
      // 取消或弹窗异常：什么都不做
    });
  }

  /** 执行播种并提示结果 */
  private async seedCloud(): Promise<void> {
    try {
      const count: number = await CloudDBUtil.seedWallpapers(CloudWallpapers.all());
      promptAction.showToast({ message: `已写入 ${count} 条，回首页下拉重试即可看到` });
    } catch (e) {
      console.error(`seedCloud failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '写入失败：检查网络与云数据库配置' });
    }
  }

  aboutToAppear(): void {
    // 文档页是覆盖层：返回键应先关它
    this.backId = EditGuard.push((): boolean => {
      this.onClose();
      return true;
    });
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
  }

  /**
   * 清除缓存：壁纸列表缓存 + 沙箱临时文件
   * 注意**不动收藏** —— 收藏是用户资产，清理缓存不该顺手删掉。
   */
  private clearCache(): void {
    WallpaperStore.clearCache();
    let files: number = 0;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const names: string[] = fileIo.listFileSync(ctx.filesDir);
      for (const n of names) {
        // 只清导出/编辑残留的临时文件；stickers 目录是用户素材，不能碰
        if (n.startsWith('zeroone_')) {
          try {
            fileIo.unlinkSync(`${ctx.filesDir}/${n}`);
            files++;
          } catch (e) {
            // 目录或已删除：忽略
          }
        }
      }
    } catch (e) {
      console.error(`clearCache failed: ${JSON.stringify(e)}`);
    }
    promptAction.showToast({ message: `缓存已清除（含 ${files} 个临时文件）` });
  }

  /** 顶部文档切换 chip */
  @Builder
  docTab(label: string, kind: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.kind === kind ? '#1A1410' : '#9A9AA5')
      .backgroundColor(this.kind === kind ? '#E6C07E' : '#1C1D22')
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(14)
      .onClick(() => {
        this.kind = kind;
      })
  }

  /** 正文段落 */
  @Builder
  paragraphs(list: string[]) {
    ForEach(list, (p: string) => {
      Text(p)
        .fontSize(13)
        .fontColor('#C8C8D0')
        .lineHeight(22)
        .width('100%')
        .margin({ bottom: 14 })
    }, (p: string, i: number) => i.toString())
  }

  build() {
    Column() {
      // ===== 顶栏 =====
      Row() {
        Text('‹')
          .fontSize(26)
          .fontColor('#FF6B6B')
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onClose();
          })
        Text('法律与关于')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('')
          .width(40)
      }
      .width('100%')
      .padding({ top: 10, bottom: 6, left: 8, right: 8 })

      // ===== 文档切换 =====
      Row({ space: 8 }) {
        this.docTab('隐私政策', DocKind.PRIVACY)
        this.docTab('用户协议', DocKind.TERMS)
        this.docTab('关于与版权', DocKind.ABOUT)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })

      // ===== 正文 =====
      Scroll() {
        Column() {
          if (this.kind === DocKind.PRIVACY) {
            this.paragraphs(this.privacy)
          } else if (this.kind === DocKind.TERMS) {
            this.paragraphs(this.terms)
          } else {
            // 关于页：先给实时版本信息，再给版权声明，最后是清除缓存
            Row() {
              Text('当前版本')
                .fontSize(13)
                .fontColor('#9A9AA5')
                .layoutWeight(1)
          Text(AppInfo.versionFull())
            // 开发期工具：长按版本号把种子数据写进云数据库（上架前可移除）
            .gesture(
              LongPressGesture()
                .onAction(() => {
                  this.confirmSeed();
                })
            )
                .fontSize(13)
                .fontColor('#F2F2F5')
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#1C1D22')
            .borderRadius(14)
            .margin({ bottom: 14 })

            this.paragraphs(this.about)

            Row() {
              Column({ space: 3 }) {
                Text('清除缓存')
                  .fontSize(14)
                  .fontColor('#F2F2F5')
                Text('清理壁纸列表缓存与导出残留文件，不会删除收藏')
                  .fontSize(11)
                  .fontColor('#7A7A85')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('清理')
                .fontSize(13)
                .fontColor('#FF6B6B')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .backgroundColor('#3A2530')
                .borderRadius(12)
                .onClick(() => {
                  this.clearCache();
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#1C1D22')
            .borderRadius(14)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F0F12')
  }
}
