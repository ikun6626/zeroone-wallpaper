import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { AppInfo } from '../utils/AppInfo';
import { EditGuard } from '../utils/EditGuard';
import { WallpaperStore } from '../store/WallpaperStore';
import { Wallpaper } from '../../model/Wallpaper';
import { LocalWallpapers } from '../constants/LocalWallpapers';
import { LEGAL_UPDATED_AT, PRIVACY_TEXTS, TERMS_TEXTS, ABOUT_TEXTS } from '../constants/LegalTexts';

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
  private readonly updatedAt: string = LEGAL_UPDATED_AT;

  /**
   * 三段法务文本统一来自 common/constants/LegalTexts.ets
   *
   * 首次启动的隐私弹窗（PrivacyConsentDialog）和本页共用同一份文案 ——
   * 如果各存一份，改文案时必然漏掉一边，而审核会对照两处，不一致会被驳。
   */
  private readonly privacy: string[] = PRIVACY_TEXTS;
  private readonly terms: string[] = TERMS_TEXTS;
  private readonly about: string[] = ABOUT_TEXTS;

  /**
   * 本地数据自检（长按版本号触发）
   *
   * 离线版没有云端可探，这里校验"目录 ↔ 本地资源"是否对得上：
   * 任何一条壁纸在 media 里找不到对应资源名，那一格的图就会是空白 ——
   * 内置 73 条时肉眼很难发现漏配，所以留一个一键自检入口。
   */
  private checkLocalData(): void {
    const all: Wallpaper[] = LocalWallpapers.ALL;
    const missing: string[] = [];
    const dup: string[] = [];
    const seen: Set<string> = new Set<string>();

    for (const w of all) {
      if (LocalWallpapers.getLocalImg(w.id) === undefined) {
        missing.push(w.id);
      }
      if (seen.has(w.id)) {
        dup.push(w.id);
      }
      seen.add(w.id);
    }

    const report: string[] = [];
    report.push(`① 壁纸目录：${all.length} 条`);
    report.push(missing.length === 0
      ? '② 图片资源：全部可解析 ✔'
      : `② 缺图 ${missing.length} 条：${missing.slice(0, 5).join('、')}${missing.length > 5 ? ' …' : ''}`);
    report.push(dup.length === 0
      ? '③ id 唯一性：无重复 ✔'
      : `③ id 重复 ${dup.length} 条：${dup.slice(0, 5).join('、')}`);
    report.push('④ 网络依赖：云端壁纸需联网，本地兜底目录可离线浏览');

    promptAction.showDialog({
      title: '本地数据自检',
      message: report.join('\n\n'),
      buttons: [{ text: '知道了', color: '#C9333D' }]
    }).catch(() => {
      // 弹窗异常时忽略：报告已经写进日志
    });
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
      .fontColor(this.kind === kind ? '#1A1410' : '#A8A8B5')
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
          .fontColor('#C9333D')
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
                .fontColor('#A8A8B5')
                .layoutWeight(1)
          Text(AppInfo.versionFull())
            // 开发期工具：长按版本号做一次本地数据自检（目录 ↔ 图片资源是否对得上）
            .gesture(
              LongPressGesture()
                .onAction(() => {
                  this.checkLocalData();
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
                  .fontColor('#A8A8B5')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('清理')
                .fontSize(13)
                .fontColor('#E8606A')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .backgroundColor('#4A2E36')
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
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F0F12')
  }
}
