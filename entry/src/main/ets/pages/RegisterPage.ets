import { AuthManager } from '../common/net/AuthManager';
import { EditGuard } from '../common/utils/EditGuard';

/**
 * RegisterPage —— 注册页
 *
 * 视觉与 LoginPage 一致（青蛙池塘 GIF 背景 + 青绿配色 + 半透明白卡片）。
 * 交互：账号 + 密码 + 确认密码 → 调 AuthManager.register()。
 *  - 账号已被注册：后端返回 409 code=USER_EXISTS → 显示"该账号已被注册"提示
 *  - 注册成功：提示"注册成功"，切回登录页让用户登录（简单注册流程，不自动登录）
 */
@Component
export struct RegisterPage {
  /** 注册成功或点"去登录"时回调（Index 切回登录页） */
  onGoLogin: () => void = () => {};
  /** 关闭注册页（返回浏览，不强制注册） */
  onClose: () => void = () => {};

  @State username: string = '';
  @State password: string = '';
  @State password2: string = '';
  @State passwordVisible: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State successMsg: string = '';

  /** 返回键处理注册 id（-1 = 未注册） */
  private backId: number = -1;

  aboutToAppear(): void {
    // 覆盖层打开期间接管返回键：只关闭本覆盖层（不退出 App）。
    // 与登录页互切时各按 id 出栈，顺序不影响最终只保留当前页的处理器。
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

  // ===== 青蛙池塘配色（与 LoginPage 一致） =====
  private readonly COLOR_DEEP: string = '#264653';
  private readonly COLOR_GOLD: string = '#E9C46A';
  private readonly COLOR_CARD: string = '#CCFFFFFF';
  private readonly COLOR_INPUT_BG: string = '#66FFFFFF';

  async doRegister(): Promise<void> {
    const u: string = this.username.trim();
    const p: string = this.password;
    const p2: string = this.password2;
    this.successMsg = '';

    if (u.length < 3) {
      this.errorMsg = '账号至少 3 个字符';
      return;
    }
    if (p.length < 6) {
      this.errorMsg = '密码至少 6 位';
      return;
    }
    if (p !== p2) {
      this.errorMsg = '两次输入的密码不一致';
      return;
    }
    this.errorMsg = '';
    this.loading = true;
    try {
      const resp = await AuthManager.getInstance().register(u, p);
      if (resp.ok) {
        this.errorMsg = '';
        this.successMsg = '注册成功，请登录';
        // 清空表单，1.2s 后切回登录页
        setTimeout(() => { this.onGoLogin(); }, 1200);
      } else {
        // 后端 409 USER_EXISTS → 账号已存在
        if (resp.code === 'USER_EXISTS') {
          this.errorMsg = '该账号已被注册，请换一个';
        } else {
          this.errorMsg = resp.message ?? '注册失败，请重试';
        }
      }
    } catch (e) {
      this.errorMsg = '网络异常，请检查网络后重试';
    } finally {
      this.loading = false;
    }
  }

  build() {
    Stack() {
      // 0. 不透明底色：GIF 解码完成前先整屏铺满，避免背后页面文字透出叠字
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.COLOR_DEEP)

      // 1. 青蛙 GIF 动态背景
      Image($rawfile('frog_bg.gif'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      // 2. 深青渐变遮罩
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#80001A1A', 0.0], ['#4D264653', 0.45], ['#B3264653', 1.0]]
        })

      // 3. 内容层
      Column({ space: 0 }) {
        // 顶部关闭栏：跳过注册，继续浏览（浏览无需登录）
        Row() {
          Text('跳过')
            .fontSize(14)
            .fontColor('#CC264653')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor('#33FFFFFF')
            .borderRadius(16)
            .onClick(() => { this.onClose(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: '8%' })

        // 顶部品牌标识
        Column({ space: 8 }) {
          Text('ZeroOne 壁纸')
            .fontSize(20)
            .fontColor(this.COLOR_GOLD)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(3)
        }
        .width('100%')
        .margin({ top: '8%', bottom: 24 })
        .justifyContent(FlexAlign.Center)

        // 标题
        Text('创建账号')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('注册后即可下载高清壁纸')
          .fontSize(14)
          .fontColor('#CCFFFFFF')
          .margin({ top: 6, bottom: 24 })
          .width('100%')

        // ===== 半透明卡片 =====
        Column({ space: 16 }) {
          // 账号
          Column({ space: 8 }) {
            Text('账号')
              .fontSize(13)
              .fontColor(this.COLOR_DEEP)
              .fontWeight(FontWeight.Medium)
            TextInput({ text: this.username, placeholder: '3-20 位字母/数字/下划线' })
              .type(InputType.Normal)
              .maxLength(20)
              .height(48)
              .width('100%')
              .backgroundColor(this.COLOR_INPUT_BG)
              .borderRadius(12)
              .border({ width: 1, color: '#33264653' })
              .placeholderColor('#99264653')
              .placeholderFont({ size: 14 })
              .fontColor(this.COLOR_DEEP)
              .fontSize(15)
              .padding({ left: 14, right: 14 })
              .onChange((v: string) => { this.username = v; this.errorMsg = ''; this.successMsg = ''; })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 密码
          Column({ space: 8 }) {
            Text('密码')
              .fontSize(13)
              .fontColor(this.COLOR_DEEP)
              .fontWeight(FontWeight.Medium)
            Row({ space: 8 }) {
              TextInput({ text: this.password, placeholder: '至少 6 位' })
                .type(this.passwordVisible ? InputType.Normal : InputType.Password)
                .showPasswordIcon(false)
                .maxLength(32)
                .height(48)
                .backgroundColor(this.COLOR_INPUT_BG)
                .borderRadius(12)
                .border({ width: 1, color: '#33264653' })
                .placeholderColor('#99264653')
                .placeholderFont({ size: 15 })
                .fontColor(this.COLOR_DEEP)
                .fontSize(15)
                .padding({ left: 14, right: 8 })
                .layoutWeight(1)
                .onChange((v: string) => { this.password = v; this.errorMsg = ''; })

              Text(this.passwordVisible ? '🙈' : '👁')
                .fontSize(20)
                .width(40)
                .height(40)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.passwordVisible = !this.passwordVisible; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 确认密码
          Column({ space: 8 }) {
            Text('确认密码')
              .fontSize(13)
              .fontColor(this.COLOR_DEEP)
              .fontWeight(FontWeight.Medium)
            TextInput({ text: this.password2, placeholder: '再输入一次密码' })
              .type(this.passwordVisible ? InputType.Normal : InputType.Password)
              .showPasswordIcon(false)
              .maxLength(32)
              .height(48)
              .width('100%')
              .backgroundColor(this.COLOR_INPUT_BG)
              .borderRadius(12)
              .border({ width: 1, color: '#33264653' })
              .placeholderColor('#99264653')
              .placeholderFont({ size: 15 })
              .fontColor(this.COLOR_DEEP)
              .fontSize(15)
              .padding({ left: 14, right: 14 })
              .onChange((v: string) => { this.password2 = v; this.errorMsg = ''; })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 错误 / 成功提示
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(13)
              .fontColor('#C24A32')
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          if (this.successMsg.length > 0) {
            Text(this.successMsg)
              .fontSize(13)
              .fontColor('#1B6B61')
              .width('100%')
              .textAlign(TextAlign.Start)
          }

          // 注册按钮
          Button(this.loading ? '注册中…' : '注册')
            .width('100%')
            .height(50)
            .backgroundColor(this.loading ? '#A6264653' : this.COLOR_DEEP)
            .fontColor('#FFFFFF')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .borderRadius(24)
            .margin({ top: 6 })
            .enabled(!this.loading)
            .onClick(() => { this.doRegister(); })
        }
        .width('100%')
        .padding(22)
        .backgroundColor(this.COLOR_CARD)
        .borderRadius(24)
        .alignItems(HorizontalAlign.Center)

        // 底部：去登录
        Row({ space: 4 }) {
          Text('已有账号？')
            .fontSize(14)
            .fontColor('#CCFFFFFF')
          Text('去登录')
            .fontSize(14)
            .fontColor(this.COLOR_GOLD)
            .fontWeight(FontWeight.Bold)
            .onClick(() => { this.onGoLogin(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 24 })

        Blank()
      }
      .width('88%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
