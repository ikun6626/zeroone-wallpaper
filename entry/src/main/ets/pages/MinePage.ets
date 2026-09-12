import { Wallpaper } from '../model/Wallpaper';
import { DefaultWallpapers } from '../common/constants/DefaultWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';
import { LegalDocPage } from '../common/components/LegalDocPage';
import { AppInfo } from '../common/utils/AppInfo';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@ohos.base';

/**
 * MinePage —— 我的页面（高级黑 · 宠物主题）
 *
 * 结构：
 *  - 主视图：商城 App 介绍卡片 + "最爱收藏"入口 + "帮助与反馈"入口
 *  - 收藏子视图：点"最爱收藏"进入（等比展示收藏）
 *  - 帮助子视图：常见问题 / 意见反馈 / 关于我们
 */
@Component
export struct MinePage {
  hideTabBar: (v: boolean) => void = (_: boolean) => {};
  /**
   * 本地收藏 ID（订阅 AppStorage 广播）
   * 任意页面切换收藏都会触发 onFavoritesChange → 本页统计与收藏列表立即同步
   */
  @StorageProp('favoriteIds') @Watch('onFavoritesChange') favorites: string[] = [];
  @State favWallpapers: Wallpaper[] = [];
  @State allWallpapers: Wallpaper[] = [];
  @State showFavorites: boolean = false;
  @State showHelp: boolean = false;
  /** 隐私政策/用户协议/关于（合规入口） */
  @State showLegal: boolean = false;
  @State faqExpanded: number = -1;
  @State feedbackText: string = '';
  @State previewItem: Wallpaper | undefined = undefined;
  /** 网络图已加载完成的壁纸 id（加载后释放本地兜底图，节省内存） */
  @State remoteReady: string[] = [];
  /** 云端壁纸列表（由 Index 入口统一拉取写入 AppStorage） */
  @StorageProp('wallpaperList') @Watch('onWallpaperChange') cloudWallpapers: Wallpaper[] = [];

  private readonly faqQ: string[] = [
    '如何收藏一张壁纸？',
    '在哪里查看我的收藏？',
    '如何把壁纸保存到手机相册？',
    '如何编辑壁纸？',
    '贴纸工作台怎么玩？',
    '为什么有些图片看起来比较模糊？',
    '使用需要注册登录吗？',
    '遇到问题如何反馈？'
  ];
  private readonly faqA: string[] = [
    '在首页或合辑页，点击壁纸卡片右下角的心形按钮即可收藏，再次点击可取消收藏。',
    '进入"我的"页面，点击"最爱收藏"即可查看你收藏的全部壁纸。',
    '打开壁纸全屏预览，点击底部的"保存图片"按钮，确认后即可保存到系统相册。',
    '全屏预览页点击"✏️ 编辑"，可进行旋转、裁剪、滤镜、纹理、文字、贴纸等操作。',
    '底部点"贴纸"标签：贴纸工作台可以把宠物从照片里抠出来贴到壁纸上；贴纸画板支持用相册照片做背景，贴满可爱贴纸后保存。',
    '部分内置壁纸分辨率有限，全屏放大后可能略显模糊，我们正在持续优化图库质量。',
    '不需要。收藏功能保存在本机，无需注册登录即可使用全部功能。',
    '请通过下方"意见反馈"或邮箱 3237145490@qq.com 联系我们，我们会尽快处理。'
  ];

  aboutToAppear(): void {
    this.applyWallpapers(this.cloudWallpapers);
  }

  /** 收藏变化（可能来自首页/合辑/预览页）→ 刷新收藏列表 */
  onFavoritesChange(): void {
    this.favWallpapers = this.allWallpapers.filter((w: Wallpaper) => this.favorites.includes(w.id));
  }

  /** 云端数据到达或更新时刷新统计与收藏列表 */
  onWallpaperChange(): void {
    this.applyWallpapers(this.cloudWallpapers);
  }

  private applyWallpapers(list: Wallpaper[]): void {
    this.allWallpapers = list;
    this.favWallpapers = list.filter((w: Wallpaper) => this.favorites.includes(w.id));
  }

  onToggleFavorite(id: string): void {
    // 写入后由 AppStorage 广播触发 onFavoritesChange，无需在此手动刷新
    PreferenceUtil.toggleFavorite(id);
  }

  private categoryCount(): number {
    return DefaultWallpapers.CATEGORIES.length - 1;
  }

  private toggleFaq(idx: number): void {
    this.faqExpanded = this.faqExpanded === idx ? -1 : idx;
  }

  async copyEmail(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, '3237145490@qq.com');
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '邮箱已复制 📋' });
    } catch (e) {
      console.error(`copy failed: ${JSON.stringify(e)}`);
    }
  }

  submitFeedback(): void {
    const content: string = this.feedbackText.trim();
    if (content.length === 0) {
      promptAction.showToast({ message: '请先输入反馈内容' });
      return;
    }
    const text: string = `反馈内容：${content}\n联系邮箱：3237145490@qq.com`;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '感谢反馈！内容已复制，可粘贴到邮件发送' });
    }).catch((e: BusinessError) => {
      console.error(`copy failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '感谢您的反馈 ❤️' });
    });
    this.feedbackText = '';
  }

  /** 等比收藏网格卡片 */
  @Builder
  favCard(item: Wallpaper) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack() {
        if (this.localOf(item) !== undefined) {
          Image(this.localOf(item))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
        if (item.imageUrl.length > 0) {
          Image(item.imageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#1C1D22')

      Text('❤️')
        .fontSize(16)
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor('#66000000')
        .borderRadius(15)
        .margin({ right: 6, bottom: 6 })
        .onClick(() => {
          this.onToggleFavorite(item.id);
        })
    }
    .width('100%')
    .aspectRatio(3 / 4)
    .borderRadius(12)
    .clip(true)
    .backgroundColor('#1C1D22')
    .onClick(() => {
      this.hideTabBar(true);
      this.previewItem = item;
    })
  }

  private localOf(item: Wallpaper): Resource | undefined {
    return DefaultWallpapers.getLocalImg(item.id);
  }

  /** 标记某张网络图已加载完成（新数组引用触发 @State 刷新） */
  private markRemoteReady(id: string): void {
    if (!this.remoteReady.includes(id)) {
      const next: string[] = this.remoteReady.slice();
      next.push(id);
      this.remoteReady = next;
    }
  }

  @Builder
  statChip(icon: string, num: string, label: string) {
    Column({ space: 2 }) {
      Text(`${icon} ${num}`)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F2F2F5')
      Text(label)
        .fontSize(11)
        .fontColor('#7A7A85')
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor('#191A1F')
    .borderRadius(12)
  }

  build() {
    Stack() {
      if (this.showFavorites) {
        // ===== 收藏子视图（等比） =====
        Column() {
          Row() {
            Text('‹')
              .fontSize(26)
              .fontColor('#FF6B6B')
              .width(40)
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.showFavorites = false;
              })
            Text('最爱收藏')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text(`${this.favorites.length} 张`)
              .fontSize(13)
              .fontColor('#7A7A85')
              .width(50)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8, left: 8, right: 8 })

          if (this.favWallpapers.length === 0) {
            Column({ space: 8 }) {
              Text('💔')
                .fontSize(42)
              Text('还没有收藏壁纸\n去首页逛逛，点卡片上的心形收藏吧')
                .fontSize(13)
                .fontColor('#7A7A85')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Grid() {
              ForEach(this.favWallpapers, (item: Wallpaper) => {
                GridItem() {
                  this.favCard(item)
                }
                .width('100%')
              }, (item: Wallpaper) => item.id)
            }
            .columnsTemplate('1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 12, right: 12, bottom: 12 })
            .layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0F0F12')
      } else if (this.showHelp) {
        // ===== 帮助与反馈子视图 =====
        Column() {
          Row() {
            Text('‹')
              .fontSize(26)
              .fontColor('#FF6B6B')
              .width(40)
              .height(40)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.showHelp = false;
              })
            Text('帮助与反馈')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text('')
              .width(40)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8, left: 8, right: 8 })

          Scroll() {
            Column({ space: 14 }) {
              // 常见问题
              Column({ space: 8 }) {
                Text('常见问题')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F2F2F5')
                  .width('100%')
                ForEach(this.faqQ, (q: string, idx: number) => {
                  Column({ space: 6 }) {
                    Row() {
                      Text(q)
                        .fontSize(14)
                        .fontColor('#E8E8EE')
                        .layoutWeight(1)
                      Text(this.faqExpanded === idx ? '−' : '＋')
                        .fontSize(16)
                        .fontColor('#FF6B6B')
                    }
                    .width('100%')
                    .onClick(() => {
                      this.toggleFaq(idx);
                    })
                    if (this.faqExpanded === idx) {
                      Text(this.faqA[idx])
                        .fontSize(12)
                        .fontColor('#9A9AA5')
                        .lineHeight(18)
                        .width('100%')
                    }
                  }
                  .width('100%')
                  .padding(14)
                  .backgroundColor('#1C1D22')
                  .borderRadius(14)
                }, (q: string, idx: number) => idx.toString())
              }
              .width('100%')

              // 意见反馈
              Column({ space: 8 }) {
                Text('意见反馈')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F2F2F5')
                  .width('100%')
                Text('你的建议是我们进步的动力。欢迎反馈使用中遇到的问题或功能建议。')
                  .fontSize(12)
                  .fontColor('#9A9AA5')
                  .lineHeight(18)
                  .width('100%')
                Row({ space: 8 }) {
                  Text('📧 3237145490@qq.com')
                    .fontSize(13)
                    .fontColor('#FF6B6B')
                    .layoutWeight(1)
                  Text('复制邮箱')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor('#FF6B6B')
                    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                    .borderRadius(12)
                    .onClick(() => {
                      this.copyEmail();
                    })
                }
                .width('100%')
                TextArea({ placeholder: '请输入你的反馈内容', text: this.feedbackText })
                  .fontSize(13)
                  .height(100)
                  .backgroundColor('#191A1F')
                  .placeholderColor('#66666F')
                  .fontColor('#E8E8EE')
                  .onChange((v: string) => {
                    this.feedbackText = v;
                  })
                Button('提交反馈')
                  .width('100%')
                  .height(40)
                  .backgroundColor('#FF6B6B')
                  .fontSize(15)
                  .fontColor(Color.White)
                  .onClick(() => {
                    this.submitFeedback();
                  })
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#1C1D22')
              .borderRadius(14)

              // 关于我们
              Column({ space: 6 }) {
                Text('关于我们')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F2F2F5')
                  .width('100%')
                Text(`ZeroOne 壁纸 v${AppInfo.version()}`)
                  .fontSize(13)
                  .fontColor('#E8E8EE')
                  .width('100%')
                Text('每天一点可爱 · 宠物主题壁纸商城。内置图片来自公开免费图库，版权归原作者所有。')
                  .fontSize(12)
                  .fontColor('#7A7A85')
                  .lineHeight(18)
                  .width('100%')
                // 合规入口：上架审核要求隐私政策/用户协议可达，这里给一个就近入口
                Text('隐私政策 · 用户协议 · 图片来源与版权 ›')
                  .fontSize(12)
                  .fontColor('#FF6B6B')
                  .width('100%')
                  .padding({ top: 2 })
                  .onClick(() => {
                    this.showLegal = true;
                  })
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#1C1D22')
              .borderRadius(14)
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 20 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0F0F12')
      } else {
        // ===== 主视图：App 介绍 + 入口（黑） =====
        Column() {
          Blank()

          // App 介绍卡片
          Column({ space: 12 }) {
            Row({ space: 14 }) {
              Stack() {
                Circle({ width: 56, height: 56 })
                  .fill('#FF6B6B')
                Text('🐾')
                  .fontSize(28)
              }
              Column({ space: 4 }) {
                Text('ZeroOne 壁纸')
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F2F2F5')
                Text('每天一点可爱 · 宠物主题')
                  .fontSize(12)
                  .fontColor('#7A7A85')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Text('ZeroOne 壁纸是一款宠物主题的高级壁纸商城：精选猫猫狗狗与萌宠壁纸，穿插自然风光、极简风格等好图。支持一键收藏、抠图贴纸与图片创作，底部「贴纸」标签还能把自家宠物做成贴纸，每天一点可爱。')
              .fontSize(13)
              .fontColor('#9A9AA5')
              .lineHeight(20)
              .width('100%')

            Row({ space: 8 }) {
              this.statChip('🖼', `${this.allWallpapers.length}`, '张壁纸')
              this.statChip('🏷', `${this.categoryCount()}`, '个分类')
              this.statChip('❤️', `${this.favorites.length}`, '个收藏')
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#1C1D22')
          .borderRadius(18)

          // 最爱收藏入口
          Row({ space: 14 }) {
            Stack() {
              Circle({ width: 42, height: 42 })
                .fill('#3A2530')
              Text('❤️')
                .fontSize(20)
            }
            Column({ space: 3 }) {
              Text('最爱收藏')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F2F2F5')
              Text('点击查看你收藏的壁纸')
                .fontSize(12)
                .fontColor('#7A7A85')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(`${this.favorites.length}`)
              .fontSize(12)
              .fontColor('#1A1410')
              .backgroundColor('#FF6B6B')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(12)
            Text('›')
              .fontSize(24)
              .fontColor('#4A4A55')
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#1C1D22')
          .borderRadius(18)
          .margin({ top: 14 })
          .onClick(() => {
            this.showFavorites = true;
          })

          // 帮助与反馈入口
          Row({ space: 14 }) {
            Stack() {
              Circle({ width: 42, height: 42 })
                .fill('#26303A')
              Text('🛟')
                .fontSize(20)
            }
            Column({ space: 3 }) {
              Text('帮助与反馈')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F2F2F5')
              Text('常见问题 · 意见反馈 · 关于我们')
                .fontSize(12)
                .fontColor('#7A7A85')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(24)
              .fontColor('#4A4A55')
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#1C1D22')
          .borderRadius(18)
          .margin({ top: 14 })
          .onClick(() => {
            this.showHelp = true;
          })

          // 隐私政策 / 用户协议 / 关于（上架审核硬性要求：这些内容必须可达）
          Row({ space: 14 }) {
            Stack() {
              Circle({ width: 42, height: 42 })
                .fill('#2A2B32')
              Text('📄')
                .fontSize(20)
            }
            Column({ space: 3 }) {
              Text('法律与关于')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F2F2F5')
              Text(`隐私政策 · 用户协议 · 版本 v${AppInfo.version()}`)
                .fontSize(12)
                .fontColor('#7A7A85')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(24)
              .fontColor('#4A4A55')
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#1C1D22')
          .borderRadius(18)
          .margin({ top: 14 })
          .onClick(() => {
            this.showLegal = true;
          })

          Blank()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 20 })
        .backgroundColor('#0F0F12')
      }

      // ===== 全屏预览 =====
      if (this.previewItem !== undefined) {
        ImagePreview({
          wallpaper: this.previewItem,
          localImg: DefaultWallpapers.getLocalImg(this.previewItem.id),
          onClose: () => {
            this.hideTabBar(false);
            this.previewItem = undefined;
            // 收藏变化已由 favoriteIds 广播处理，这里无需再手动同步
          }
        })
      }
      // ===== 法律与关于（隐私政策/用户协议/关于与版权） =====
      if (this.showLegal) {
        LegalDocPage({
          onClose: () => {
            this.showLegal = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
