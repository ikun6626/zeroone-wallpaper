import { PRIVACY_TEXTS, TERMS_TEXTS } from '../constants/LegalTexts';

/**
 * PrivacyConsentDialog —— 首次启动的隐私政策同意弹窗（全屏遮罩）
 *
 * 为什么必须有 —— 这是审核驳回的原文：
 *   「应用在首次启动、注册登录界面均未明确提示用户阅读隐私政策，不符合相关法律法规要求。
 *     修改建议：请在应用首次启动时通过弹出隐私政策弹窗，或在应用注册、登录界面展示
 *     隐私政策等显著方式，提示用户阅读隐私政策。」（《审核指南》第 7.5 项）
 *
 * 合规要点（每一条都踩到才算过，少一条会被二次驳回）：
 *  1. 必须**用户主动点击**「同意并继续」才能进主界面 —— 不能默认同意、不能点空白处关闭；
 *  2.「不同意」要能**真正退出应用**（不是只把弹窗关掉）；
 *  3. 弹窗里要能读到**隐私政策全文**，不能只有一行提示；
 *  4. 同意后要**持久化**，不能每次启动都弹（否则用户没法用）；
 *  5. 记的是"版本号"而不是 `true` —— 隐私政策文案更新后应重新征得同意，这是合规做法。
 *
 * 交互为两步式：概要页 →（点标题进入）全文页 → 返回概要页 → 同意/不同意。
 * 不引入 CustomDialog 是为了和工程里其它覆盖层（LegalDocPage / ImagePreview）保持同一套写法。
 */
@Component
export struct PrivacyConsentDialog {
  /** 用户点了「同意并继续」 */
  onAgree: () => void = () => {};
  /** 用户点了「不同意」（父组件负责退出应用） */
  onReject: () => void = () => {};

  /** 0 = 概要，1 = 隐私政策全文，2 = 用户协议全文 */
  @State stage: number = 0;

  /** 全文页的正文 */
  private textsFor(stage: number): string[] {
    return stage === 1 ? PRIVACY_TEXTS : TERMS_TEXTS;
  }

  @Builder
  docLink(title: string, sub: string, target: number) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor('#F0D08A')
          .width('100%')
        Text(sub)
          .fontSize(11.5)
          .fontColor('#A8A8B5')
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(20)
        .fontColor('#A8A8B5')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor('#1C1D22')
    .borderRadius(11)
    .onClick(() => {
      this.stage = target;
    })
  }

  /** 概要页 */
  @Builder
  summary() {
    Column({ space: 14 }) {
      Text('隐私政策与用户协议')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
        .width('100%')

      Text('欢迎使用 ZeroOne 壁纸。我们非常重视你的个人信息保护。')
        .fontSize(13.5)
        .fontColor('#B9B9C4')
        .lineHeight(21)
        .width('100%')

      Column({ space: 6 }) {
        Text('云端壁纸 · 无需注册即可浏览')
          .fontSize(13.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F0D08A')
          .width('100%')
        Text('壁纸内容通过网络从开发者服务器获取。浏览与收藏无需登录；保存图片需登录账号，'
          + '此时收集用户名与密码哈希。浏览不识别身份、不生成画像，'
          + '未接入任何第三方广告或数据采集 SDK。收藏仅保存在本机，暂不与账号合并。')
          .fontSize(12.5)
          .fontColor('#B9B9C4')
          .lineHeight(19)
          .width('100%')
      }
      .width('100%')
      .padding(13)
      .backgroundColor('#1A1519')
      .borderRadius(11)

      Text('请在使用前仔细阅读并同意以下条款。你可以随时在'
        + '「我的 → 法律与关于」中查看完整内容。')
        .fontSize(12.5)
        .fontColor('#A8A8B5')
        .lineHeight(19)
        .width('100%')

      this.docLink('《隐私政策》', '我们如何收集、使用与保护你的信息', 1)
      this.docLink('《用户协议》', '使用本应用的权利与义务', 2)
    }
    .width('100%')
  }

  /** 全文页 */
  @Builder
  fullText() {
    Column({ space: 0 }) {
      Row() {
        Text('‹')
          .fontSize(24)
          .fontColor('#C9333D')
          .width(34)
          .height(30)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.stage = 0;
          })
        Text(this.stage === 1 ? '隐私政策' : '用户协议')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .layoutWeight(1)
        Text('返回')
          .fontSize(12.5)
          .fontColor('#A8A8B5')
          .onClick(() => {
            this.stage = 0;
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.textsFor(this.stage), (para: string) => {
            Text(para)
              .fontSize(12.5)
              .fontColor('#B9B9C4')
              .lineHeight(20)
              .width('100%')
          }, (para: string, idx: number) => `${this.stage}-${idx}`)
        }
        .width('100%')
        .padding({ bottom: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)

      Text('已滑到底可点上方「返回」回到同意按钮')
        .fontSize(11)
        .fontColor('#A8A8B5')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 8 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      Column() {
        if (this.stage === 0) {
          this.summary()
        } else {
          this.fullText()
        }

        // 只在概要页显示同意/不同意 —— 全文页必须先返回，
        // 避免用户没看就顺手点了同意
        if (this.stage === 0) {
          Row({ space: 12 }) {
            Button('不同意')
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .fontColor('#B9B9C4')
              .backgroundColor('#26272E')
              .onClick(() => {
                this.onReject();
              })
            Button('同意并继续')
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#C9333D')
              .onClick(() => {
                this.onAgree();
              })
          }
          .width('100%')
          .padding({ top: 18 })

          Text('点击「同意并继续」即表示你已阅读并同意《隐私政策》与《用户协议》')
            .fontSize(10.5)
            .fontColor('#FFFFFF')
            .lineHeight(16)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10 })
        }
      }
      .width('86%')
      .constraintSize({ maxWidth: 460 })
      .padding({ left: 20, right: 20, top: 22, bottom: 20 })
      .backgroundColor('#17171C')
      .borderRadius(18)
      .border({ width: 1, color: '#2A2B33' })
      // 高度自适应，全文页给个上限免得撑爆屏幕
      .constraintSize({ maxHeight: '86%' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#CC000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 吞掉点击，防止穿透到下面的页面
    .onClick(() => {})
  }
}
