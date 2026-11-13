import { AuthManager } from '../net/AuthManager';
import { ApiResponse } from '../net/HttpClient';
import { EditGuard } from '../utils/EditGuard';
import { Haptics } from '../utils/Haptics';
import { promptAction } from '@kit.ArkUI';

/**
 * AccountPage —— 账号设置（覆盖在「我的」之上）
 *
 * 法规要求：账号体系必须提供**自助注销入口**，且路径要能说清。
 * 本页提供：
 *   - 账号信息（用户名 / 登录时间）
 *   - 修改昵称
 *   - 退出登录（保留账号）
 *   - 注销账号（二次确认 + 密码校验，删除服务端账号数据）
 *
 * 隐私政策里写的「我的 → 账号设置 → 注销账号」指的就是这里。
 */
@Component
export struct AccountPage {
  onClose: () => void = () => {};

  /** 当前用户名（登录后从本地读取） */
  @State username: string = '';
  @State nickname: string = '';
  @State nicknameEditing: boolean = false;
  @State busy: boolean = false;
  /** 注销确认弹窗里的密码输入 */
  @State deletePassword: string = '';
  @State showDeleteConfirm: boolean = false;

  /** 返回键处理注册 id（-1 = 未注册） */
  private backId: number = -1;

  aboutToAppear(): void {
    const am: AuthManager = AuthManager.getInstance();
    this.username = am.getUsername();
    this.nickname = am.getUsername();
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

  /** 保存昵称 */
  private saveNickname(): void {
    const name: string = this.nickname.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '昵称不能为空' });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    AuthManager.getInstance().updateNickname(name).then((resp: ApiResponse<object>): void => {
      this.busy = false;
      if (resp.ok) {
        this.nicknameEditing = false;
        promptAction.showToast({ message: '昵称已更新' });
      } else {
        promptAction.showToast({ message: resp.message ?? '修改失败，请重试' });
      }
    }).catch((): void => {
      this.busy = false;
      promptAction.showToast({ message: '网络异常，请稍后重试' });
    });
  }

  /**
   * 退出登录（先二次确认）
   *
   * 此前点一下直接退出，误触代价不小（要重新输账号密码），
   * 且和「注销账号」的危险操作提示等级倒挂 —— 注销有确认、退出反而没有。
   */
  private confirmLogout(): void {
    promptAction.showDialog({
      title: '退出登录？',
      message: '退出后需重新登录才能使用账号相关功能；本机收藏与已保存图片不受影响。',
      buttons: [
        { text: '取消', color: '#A8A8B5' },
        { text: '退出', color: '#C9333D' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 1) {
        return;
      }
      AuthManager.getInstance().logout();
      promptAction.showToast({ message: '已退出登录' });
      this.onClose();
    }).catch((): void => {});
  }

  /** 确认注销：调后端删除账号 */
  private doDeleteAccount(): void {
    if (this.deletePassword.length < 6) {
      promptAction.showToast({ message: '请输入当前密码（至少 6 位）' });
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    AuthManager.getInstance().deleteAccount(this.deletePassword).then((resp: ApiResponse<boolean>): void => {
      this.busy = false;
      if (resp.ok) {
        this.showDeleteConfirm = false;
        promptAction.showToast({ message: '账号已注销，感谢使用' });
        this.onClose();
      } else {
        promptAction.showToast({ message: resp.message ?? '注销失败，请检查密码' });
      }
    }).catch((): void => {
      this.busy = false;
      promptAction.showToast({ message: '网络异常，请稍后重试' });
    });
  }

  @Builder
  settingRow(icon: string, title: string, subtitle: string, danger: boolean,
    onTap: () => void) {
    Row({ space: 14 }) {
      Text(icon).fontSize(20).width(28).textAlign(TextAlign.Center)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(danger ? '#E8606A' : '#F2F2F5')
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(11)
            .fontColor('#A8A8B5')
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›').fontSize(20).fontColor('#8A8A95')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#1C1D22')
    .borderRadius(16)
    .onClick(() => {
      Haptics.light();
      onTap();
    })
  }

  build() {
    Stack() {
      // 背景
      Column().width('100%').height('100%').backgroundColor('#0F0F12')

      Column() {
        // ===== 顶部栏 =====
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
          Text('账号设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2F2F5')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('').width(40)
        }
        .width('100%')
        .padding({ top: 10, bottom: 8, left: 8, right: 8 })

        Scroll() {
          Column({ space: 14 }) {
            // ===== 账号信息 =====
            Column({ space: 10 }) {
              Row({ space: 14 }) {
                Stack() {
                  Circle({ width: 48, height: 48 }).fill('#4A2E36')
                  Text(this.nickname.length > 0 ? this.nickname.charAt(0).toUpperCase() : '游')
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FFFFFF')
                }
                Column({ space: 3 }) {
                  if (this.nicknameEditing) {
                    TextInput({ text: this.nickname })
                      .height(38)
                      .fontSize(14)
                      .fontColor('#F2F2F5')
                      .backgroundColor('#191A1F')
                      .borderRadius(10)
                      .onChange((v: string) => {
                        this.nickname = v;
                      })
                  } else {
                    Text(this.nickname.length > 0 ? this.nickname : '未设置昵称')
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#F2F2F5')
                  }
                  Text(`登录账号：${this.username}`)
                    .fontSize(11)
                    .fontColor('#A8A8B5')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.nicknameEditing) {
                  Text(this.busy ? '保存中…' : '保存')
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#C9333D')
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(12)
                    .onClick(() => {
                      this.saveNickname();
                    })
                } else {
                  Text('改昵称')
                    .fontSize(13)
                    .fontColor('#E8606A')
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor('#33C9333D')
                    .borderRadius(12)
                    .onClick(() => {
                      this.nicknameEditing = true;
                    })
                }
              }
              .width('100%')

              Text('账号用于保存图片；收藏保存在本机，暂不跨设备同步；密码在服务端以不可逆哈希保存，我们无法看到明文。')
                .fontSize(11)
                .fontColor('#A8A8B5')
                .lineHeight(17)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#1C1D22')
            .borderRadius(16)

            // ===== 退出登录 =====
            this.settingRow('🚪', '退出登录', '保留账号，下次可重新登录；收藏仍保存在本机', false, () => {
              this.confirmLogout();
            })

            // ===== 注销账号 =====
            this.settingRow('⚠️', '注销账号', '永久删除服务端账号数据（用户名、密码哈希、昵称），不可恢复；本机收藏与已保存图片不受影响', true, () => {
              this.deletePassword = '';
              this.showDeleteConfirm = true;
            })

            Text('注销后：服务端账号数据立即删除；本机收藏、导出图片、缓存仍保留，需要时可在「法律与关于 → 清除缓存」里清理。')
              .fontSize(11)
              .fontColor('#8A8A95')
              .lineHeight(17)
              .width('100%')
              .padding({ left: 4, right: 4 })

            Blank()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      // ===== 注销二次确认 =====
      if (this.showDeleteConfirm) {
        Column() {
          Column({ space: 14 }) {
            Text('注销账号？')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
            Text('此操作会立即删除服务端账号数据，且无法恢复。请输入当前密码确认。')
              .fontSize(12)
              .fontColor('#A8A8B5')
              .lineHeight(19)
              .width('100%')

            TextInput({ placeholder: '当前密码' })
              .type(InputType.Password)
              .height(44)
              .fontSize(14)
              .fontColor('#F2F2F5')
              .backgroundColor('#191A1F')
              .borderRadius(12)
              .placeholderColor('#A8A8B5')
              .onChange((v: string) => {
                this.deletePassword = v;
              })

            Row({ space: 10 }) {
              Button('取消')
                .fontSize(14)
                .fontColor('#F2F2F5')
                .backgroundColor('#2A2B32')
                .layoutWeight(1)
                .height(42)
                .onClick(() => {
                  this.showDeleteConfirm = false;
                })
              Button(this.busy ? '处理中…' : '确认注销')
                .fontSize(14)
                .fontColor(Color.White)
                .backgroundColor('#C9333D')
                .layoutWeight(1)
                .height(42)
                .enabled(!this.busy)
                .onClick(() => {
                  this.doDeleteAccount();
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(20)
          .backgroundColor('#1C1D22')
          .borderRadius(18)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
