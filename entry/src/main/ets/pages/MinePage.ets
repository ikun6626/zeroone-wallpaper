import { Wallpaper } from '../model/Wallpaper';
import { LocalWallpapers } from '../common/constants/LocalWallpapers';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { ImagePreview } from '../common/components/ImagePreview';
import { LegalDocPage } from '../common/components/LegalDocPage';
import { AccountPage } from '../common/components/AccountPage';
import { AppInfo } from '../common/utils/AppInfo';
import { AuthManager } from '../common/net/AuthManager';
import { AlbumsApi, AppStats } from '../common/net/AlbumsApi';
import { ApiConfig } from '../common/net/ApiConfig';
import { HttpClient, ApiResponse } from '../common/net/HttpClient';
import { StoreKeys } from '../common/store/WallpaperStore';
import { RemoteImage } from '../common/components/RemoteImage';
import { Haptics } from '../common/utils/Haptics';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@ohos.base';

/** 反馈请求体（POST /api/v1/feedback，ArkTS 要求显式类型） */
export class FeedbackBody {
  content: string = '';
  contact: string = '';
}

/**
 * MinePage —— 我的页面（高级黑 · 云端壁纸）
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
  /** 壁纸列表（由 Index 入口统一发布写入 AppStorage） */
  @StorageProp('wallpaperList') @Watch('onWallpaperChange') catalogWallpapers: Wallpaper[] = [];
  /** 是否已登录（订阅 AppStorage，AuthManager 登录/登出自动刷新账号卡片） */
  @StorageLink(ApiConfig.APP_KEY_LOGGED_IN) isLoggedIn: boolean = false;
  /** 登录用户名（登录后显示） */
  @State authUsername: string = '';
  /** 账号设置覆盖层（含注销账号入口） */
  @State showAccount: boolean = false;
  /**
   * 云端实时统计文本（初始「--」：未取到/取失败都显示它，不回退本地兜底数 315/5）。
   * 直接用字符串状态：@Builder 按值传参只追踪"直接传入的状态变量"，传方法
   * 返回值（statNum(...)）不会触发重渲染，所以文本在此处就准备好。
   * 本页每次变为可见时刷新，后台上图/建合辑后下次进「我的」就是最新值。
   */
  @State wallpaperNumText: string = '--';
  @State albumNumText: string = '--';

  private readonly faqQ: string[] = [
    '如何收藏一张壁纸？',
    '在哪里查看我的收藏？',
    '如何把壁纸保存到手机相册？',
    '如何编辑壁纸？',
    '贴纸专区怎么玩？',
    '为什么有些图片看起来比较模糊？',
    '使用需要注册登录吗？',
    '应用需要联网吗？',
    '遇到问题如何反馈？'
  ];
  private readonly faqA: string[] = [
    '在首页或合辑页，点击壁纸卡片上的心形按钮即可收藏，再次点击可取消收藏。',
    '进入"我的"页面，点击"最爱收藏"即可查看你收藏的全部壁纸。',
    '打开壁纸全屏预览，点击底部工具栏的下载图标，确认后即可保存到系统相册。注意：受 HarmonyOS 系统限制，第三方应用无法直接替换系统壁纸，保存后需你在系统「图库」中手动完成设置。',
    '全屏预览页点击底部工具栏的调色盘图标，可进行旋转、裁剪、滤镜、纹理、文字、贴纸等操作。',
    '底部点"贴纸"标签即进入贴纸专区：① 选背景（内置壁纸库或相册照片，也可以不选背景，直接导出透明 PNG）；② 从 51 款猫猫/狗狗/兔兔贴纸里挑喜欢的贴上，支持拖动、缩放、旋转、阴影与调色，常用贴纸可点右上角星标收藏；③ 导出时可选存 JPG、透明 PNG，或存为锁屏/桌面壁纸用图。专区还支持撤销/重做与图层管理。本应用不提供自动抠图，如需使用自己的贴纸，请先准备好透明 PNG 再导入。',
    '不同壁纸的来源分辨率不一，极少数图片全屏放大后可能略显模糊，我们正在持续优化图库质量。',
    '不需要登录即可使用：浏览、收藏、编辑、贴纸、保存相册全部无需注册。注册账号为可选项，不影响任何核心功能，账号可在「我的 → 账号设置」里随时注销。',
    '部分功能需要联网。壁纸库会优先从云端更新（联网时自动加载最新壁纸），断网时自动使用内置壁纸，不影响使用；收藏、贴纸、编辑等核心功能均可离线使用。',
    '点击下方"提交反馈"会直接发送到我们的反馈后台；网络不可用时，内容会自动复制到剪贴板，请粘贴后发送至 zeroone@example.com，我们会尽快处理。'
  ];

  aboutToAppear(): void {
    this.rebuildFavorites();
    this.authUsername = AuthManager.getInstance().getUsername();
  }

  /** 点击"登录/注册"：弹出登录覆盖层（不挡主界面，盖在最上层） */
  onLoginTap(): void {
    this.authUsername = AuthManager.getInstance().getUsername();
    AuthManager.getInstance().showAuthOverlay();
  }

  /** 登出 */
  onLogout(): void {
    AuthManager.getInstance().logout();
    this.authUsername = '';
    promptAction.showToast({ message: '已退出登录' });
  }

  /** 收藏变化（可能来自首页/合辑/预览页）→ 刷新收藏列表 */
  onFavoritesChange(): void {
    this.rebuildFavorites();
  }

  /** 数据到达或更新时刷新统计与收藏列表 */
  onWallpaperChange(): void {
    this.rebuildFavorites();
  }

  /**
   * 重建收藏列表（单一入口：收藏变化 / 目录变化 / 页面变为可见都会走这里）
   *
   * 数据源两级：
   *  1. 壁纸目录（AppStorage 里的 wallpaperList，含最新云端地址）；
   *  2. 收藏快照（PreferenceUtil.getFavoriteItems，收藏时登记的对象）——
   *     覆盖"目录里没有的图"：云端目录只随翻页增长，从合辑详情收藏的
   *     图大多不在已加载的分页里，没有快照就会显示不出来。
   * 另兼容历史版本从合辑详情收藏的 `c_<serverId>` 记录（按 serverId 反查）。
   */
  private rebuildFavorites(): void {
    const ids: string[] = PreferenceUtil.getFavoriteIds();
    // 注意：给 @StorageProp favorites 赋值会触发 @Watch('onFavoritesChange')
    // → 又调本方法。内容一致时必须跳过赋值，否则无限递归栈溢出闪退。
    if (!this.sameIds(this.favorites, ids)) {
      this.favorites = ids;
    }
    const catalog: Wallpaper[] = AppStorage.get<Wallpaper[]>(StoreKeys.LIST) ?? this.allWallpapers;
    this.allWallpapers = catalog;
    const snaps: Wallpaper[] = PreferenceUtil.getFavoriteItems();
    const out: Wallpaper[] = [];
    for (let i = 0; i < ids.length; i++) {
      const hit: Wallpaper | undefined = this.findByIdIn(catalog, ids[i]);
      if (hit === undefined) {
        const snap: Wallpaper | undefined = this.findByIdIn(snaps, ids[i]);
        if (snap === undefined) {
          continue;
        }
        out.push(snap);
      } else {
        out.push(hit);
      }
    }
    this.favWallpapers = out;
  }

  /** 全屏预览左右滑：在「最爱收藏」列表里取相邻一张（尽头返回 undefined） */
  private neighborOf(current: Wallpaper, dir: number): Wallpaper | undefined {
    let idx: number = -1;
    for (let i = 0; i < this.favWallpapers.length; i++) {
      if (this.favWallpapers[i].id === current.id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return undefined;
    }
    const next: number = idx + dir;
    if (next < 0 || next >= this.favWallpapers.length) {
      return undefined;
    }
    return this.favWallpapers[next];
  }

  /** 逐项比较两个 id 数组内容是否一致 */
  private sameIds(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /** 在列表里按 id（或历史别名 c_<serverId>）找壁纸 */
  private findByIdIn(list: Wallpaper[], fid: string): Wallpaper | undefined {
    for (let i = 0; i < list.length; i++) {
      const w: Wallpaper = list[i];
      if (w.id === fid) {
        return w;
      }
      if (fid.startsWith('c_') && w.serverId > 0 && fid === `c_${w.serverId}`) {
        return w;
      }
    }
    return undefined;
  }

  onToggleFavorite(id: string, item: Wallpaper): void {
    // 写入后由 AppStorage 广播触发 onFavoritesChange，无需在此手动刷新；
    // 传 item 让快照同步登记/清理（目录里没有的图取消收藏也能清干净）
    PreferenceUtil.toggleFavoriteItem(id, item);
  }

  /** 拉取云端实时统计（每次本页可见时调用；失败保持「--」，不用本地数误导） */
  private async loadCloudStats(): Promise<void> {
    const stats: AppStats | null = await AlbumsApi.fetchStats();
    if (stats !== null) {
      this.wallpaperNumText = `${stats.wallpapers}`;
      this.albumNumText = `${stats.albums}`;
    }
  }

  private toggleFaq(idx: number): void {
    this.faqExpanded = this.faqExpanded === idx ? -1 : idx;
  }

  async copyEmail(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, 'zeroone@example.com');
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '邮箱已复制 📋' });
    } catch (e) {
      console.error(`copy failed: ${JSON.stringify(e)}`);
    }
  }

  /** 提交反馈：优先直连管理后台；网络不可用时退回复制到剪贴板（邮件兜底） */
  async submitFeedback(): Promise<void> {
    const content: string = this.feedbackText.trim();
    if (content.length === 0) {
      promptAction.showToast({ message: '请先输入反馈内容' });
      return;
    }
    const body = new FeedbackBody();
    body.content = content;
    body.contact = 'zeroone@example.com';
    const resp: ApiResponse<object> = await HttpClient.post<object>(ApiConfig.PATH.FEEDBACK, body);
    if (resp.ok) {
      promptAction.showToast({ message: '感谢您的反馈 ❤️ 我们会尽快处理' });
      this.feedbackText = '';
      return;
    }
    // 网络失败兜底：复制到剪贴板，引导邮件发送
    const text: string = `反馈内容：${content}\n联系邮箱：zeroone@example.com`;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '网络不可用，内容已复制，可粘贴到邮件发送' });
    }).catch((e: BusinessError) => {
      console.error(`copy failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '提交失败，请检查网络后重试' });
    });
  }

  /** 等比收藏网格卡片 */
  @Builder
  favCard(item: Wallpaper) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 收藏缩略图：云端优先、随包兜底，Cover 饱满（点击进全屏预览）
      RemoteImage({
        url: item.thumbUrl.length > 0 ? item.thumbUrl : item.imageUrl,
        fallback: this.localOf(item),
        fit: ImageFit.Cover
      })
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
          Haptics.light();
          this.onToggleFavorite(item.id, item);
        })
    }
    .width('100%')
    .aspectRatio(3 / 4)
    .borderRadius(12)
    .clip(true)
    .backgroundColor('#1C1D22')
    .geometryTransition(`wpic_${item.id}`)
    .onClick(() => {
      Haptics.light();
      this.hideTabBar(true);
      animateTo({ duration: 320, curve: Curve.EaseOut }, (): void => {
        this.previewItem = item;
      });
    })
  }

  private localOf(item: Wallpaper): Resource | undefined {
    return LocalWallpapers.getThumb(item.id);
  }


  /**
   * 统计 chip。
   * 注意：num 不作为参数传入 —— 实测 @Builder 按值参数在状态变化时不刷新
   * （直接引用状态的同页 Text 能正常刷新）。这里按 key 在内部直接读状态，
   * 让状态变量出现在 @Builder 的 UI 表达式里，刷新才生效。
   */
  @Builder
  statChip(icon: string, key: string, label: string) {
    Column({ space: 2 }) {
      if (key === 'wallpapers') {
        Text(`${icon} ${this.wallpaperNumText}`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
      } else if (key === 'albums') {
        Text(`${icon} ${this.albumNumText}`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
      } else {
        // 收藏数与列表一致：用解析成功的条目数（历史遗留 id 可能无法解析展示）
        Text(`${icon} ${this.favWallpapers.length}`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
      }
      Text(label)
        .fontSize(11)
        .fontColor('#A8A8B5')
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
              .fontColor('#C9333D')
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
            Text(`${this.favWallpapers.length} 张`)
              .fontSize(13)
              .fontColor('#A8A8B5')
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
                .fontColor('#A8A8B5')
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
            .edgeEffect(EdgeEffect.Spring)
            .enableScrollInteraction(true)
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
              .fontColor('#C9333D')
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
                        .fontColor('#E8606A')
                    }
                    .width('100%')
                    .onClick(() => {
                      this.toggleFaq(idx);
                    })
                    if (this.faqExpanded === idx) {
                      Text(this.faqA[idx])
                        .fontSize(12)
                        .fontColor('#A8A8B5')
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
                Text('你的建议是我们进步的动力。点击下方「提交反馈」会直接发送到反馈后台；网络不可用时，内容会自动复制到剪贴板，请粘贴后发送至下方邮箱，我们会尽快回复。')
                  .fontSize(12)
                  .fontColor('#A8A8B5')
                  .lineHeight(18)
                  .width('100%')
                Row({ space: 8 }) {
                  Text('📧 zeroone@example.com')
                    .fontSize(13)
                    .fontColor('#E8606A')
                    .layoutWeight(1)
                  Text('复制邮箱')
                    .fontSize(12)
                    .fontColor(Color.White)
                    .backgroundColor('#C9333D')
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
                  .placeholderColor('#A8A8B5')
                  .fontColor('#E8E8EE')
                  .onChange((v: string) => {
                    this.feedbackText = v;
                  })
                Button('提交反馈')
                  .width('100%')
                  .height(40)
                  .backgroundColor('#C9333D')
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
                Text('云端壁纸持续更新，无需登录即可浏览。壁纸部分来自公开免费图库与公开网络渠道，版权归原作者所有。')
                  .fontSize(12)
                  .fontColor('#A8A8B5')
                  .lineHeight(18)
                  .width('100%')
                // 合规入口：上架审核要求隐私政策/用户协议可达，这里给一个就近入口
                Text('隐私政策 · 用户协议 · 图片来源与版权 ›')
                  .fontSize(12)
                  .fontColor('#E8606A')
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
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#0F0F12')
      } else {
        // ===== 主视图：App 介绍 + 入口（黑） =====
        Column() {
          // 账号卡片：未登录显示"登录/注册"，已登录显示用户名 + 登出
          Row({ space: 14 }) {
            Stack() {
              Circle({ width: 48, height: 48 })
                .fill(this.isLoggedIn ? '#2A9D8F' : '#4A2E36')
              Text(this.isLoggedIn ? this.authUsername.charAt(0).toUpperCase() : '游')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            Column({ space: 3 }) {
              Text(this.isLoggedIn ? this.authUsername : '游客')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F2F2F5')
              Text(this.isLoggedIn ? '已登录' : '无需登录，收藏保存在本机')
                .fontSize(12)
                .fontColor('#A8A8B5')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (this.isLoggedIn) {
              Text('账号设置')
                .fontSize(13)
                .fontColor('#F2F2F5')
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('#2A2B32')
                .borderRadius(14)
                .onClick(() => {
                  Haptics.light();
                  this.showAccount = true;
                })
            } else {
              // 账号体系已上线（注册/登录/注销都有后端接口）：
              // 未登录时给出明确的登录入口与"登录后能做什么"说明。
              Text('登录 / 注册')
                .fontSize(13)
                .fontColor('#FFFFFF')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor('#C9333D')
                .borderRadius(14)
                .onClick(() => {
                  Haptics.light();
                  AuthManager.getInstance().showAuthOverlay();
                })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#1C1D22')
          .borderRadius(18)
          .margin({ top: 12, bottom: 14 })
          .onClick(() => {
            // 整卡可点：未登录弹登录，已登录进账号设置
            if (this.isLoggedIn) {
              this.showAccount = true;
            }
          })

          // App 介绍卡片
          Column({ space: 12 }) {
            Row({ space: 14 }) {
              Stack() {
                Circle({ width: 56, height: 56 })
                  .fill('#C9333D')
                Text('🐾')
                  .fontSize(28)
              }
              Column({ space: 4 }) {
                Text('ZeroOne 壁纸')
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#F2F2F5')
                Text('云端壁纸 · 每日持续更新')
                  .fontSize(12)
                  .fontColor('#A8A8B5')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Text('ZeroOne 壁纸是一款云端壁纸工具：风景、动物、插画、文字等高清壁纸持续更新，无需登录即可浏览全部。支持一键收藏（仅保存在本机）、全屏预览与保存到相册；底部「贴纸」标签提供 51 款宠物贴纸，可自由拼贴创作，也支持导入你自己的透明 PNG 贴纸。')
              .fontSize(13)
              .fontColor('#A8A8B5')
              .lineHeight(20)
              .width('100%')

            Row({ space: 8 }) {
              this.statChip('🖼', 'wallpapers', '张壁纸')
              this.statChip('🏷', 'albums', '个合辑')
              this.statChip('❤️', 'favorites', '个收藏')
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
                .fill('#4A2E36')
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
                .fontColor('#A8A8B5')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(`${this.favWallpapers.length}`)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor('#C9333D')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(12)
            Text('›')
              .fontSize(24)
              .fontColor('#FFFFFF')
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
                .fontColor('#A8A8B5')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(24)
              .fontColor('#A8A8B5')
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
                .fontColor('#A8A8B5')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(24)
              .fontColor('#A8A8B5')
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
          neighbor: (current: Wallpaper, dir: number): Wallpaper | undefined => this.neighborOf(current, dir),
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

      // ===== 账号设置（含法规要求的"注销账号"入口） =====
      if (this.showAccount) {
        AccountPage({
          onClose: () => {
            this.showAccount = false;
            this.authUsername = AuthManager.getInstance().getUsername();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .onVisibleAreaChange([0.0], (isVisible: boolean, ratio: number): void => {
      // 进入「我的」tab 即刷新云端统计（后台上图后数字实时更新）
      if (isVisible) {
        // 本 Tab 在后台时被框架冻结，@Watch 不投递（目录/收藏的变更收不到），
        // 变为可见时必须主动重同步，否则「最爱收藏」是旧数据甚至空白
        this.rebuildFavorites();
        this.loadCloudStats();
      }
    })
  }
}
