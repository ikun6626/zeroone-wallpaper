import { SystemApi, NoticeItem } from '../net/SystemApi';
import { Haptics } from '../utils/Haptics';

/**
 * NoticePage —— 公告列表（全屏覆盖层组件，2026-10-25「回访闭环」第一批）
 *
 * 数据：后台 `GET /api/v1/notices`（管理后台「公告管理」维护，按 sort/时间窗过滤）。
 * 交互：标题行点击展开/收起正文（与 MinePage 常见问题的手风琴交互一致）。
 * 容错：接口失败/无公告显示空态，不阻塞其它功能。
 */
@Component
export struct NoticePage {
  onClose: () => void = (): void => {};
  /** 公告列表 */
  @State notices: NoticeItem[] = [];
  @State loading: boolean = true;
  /** 当前展开的公告 id（-1 = 全部收起） */
  @State expandedId: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const list: NoticeItem[] = await SystemApi.fetchNotices();
    this.notices = list;
    // 默认展开第一条，用户打开就能看到最新公告正文
    if (list.length > 0) {
      this.expandedId = list[0].id;
    }
    this.loading = false;
  }

  private toggle(id: number): void {
    Haptics.light();
    this.expandedId = this.expandedId === id ? -1 : id;
  }

  /** ISO 时间串 → "2026-10-25"（异常返回空串） */
  private dateOf(iso: string): string {
    if (iso.length < 10) {
      return '';
    }
    return iso.substring(0, 10);
  }

  build() {
    Column() {
      // 顶部返回栏（与收藏/帮助子视图同构）
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
        Text('公告')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(`${this.notices.length}`)
          .fontSize(13)
          .fontColor('#A8A8B5')
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8, left: 8, right: 12 })

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color('#C9333D')
          Text('正在加载公告…')
            .fontSize(12)
            .fontColor('#A8A8B5')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.notices.length === 0) {
        Column({ space: 10 }) {
          Text('📣')
            .fontSize(42)
          Text('暂无公告')
            .fontSize(14)
            .fontColor('#A8A8B5')
          Text('有新内容时会在这里通知你')
            .fontSize(12)
            .fontColor('#6F6F7A')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            ForEach(this.notices, (n: NoticeItem) => {
              Column({ space: 8 }) {
                Row() {
                  Text(n.title)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#F2F2F5')
                    .layoutWeight(1)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.expandedId === n.id ? '−' : '＋')
                    .fontSize(16)
                    .fontColor('#E8606A')
                    .margin({ left: 8 })
                }
                .width('100%')
                .onClick(() => {
                  this.toggle(n.id);
                })

                if (this.dateOf(n.createdAt).length > 0) {
                  Text(this.dateOf(n.createdAt))
                    .fontSize(11)
                    .fontColor('#6F6F7A')
                    .width('100%')
                }

                if (this.expandedId === n.id && n.content.length > 0) {
                  Text(n.content)
                    .fontSize(13)
                    .fontColor('#A8A8B5')
                    .lineHeight(20)
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(14)
              .backgroundColor('#1C1D22')
              .borderRadius(14)
            }, (n: NoticeItem) => n.id.toString())
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 20 })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F0F12')
  }
}
